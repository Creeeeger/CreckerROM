#!/usr/bin/env python3
# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later
"""Install OMC applications through Samsung's removable preload installer."""

import argparse
from contextlib import closing
import gzip
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def relocated(value, moves):
    for source, destination in moves:
        if value == source or value.startswith(source + "/"):
            return destination + value[len(source):]
    return value


def update_metadata(work, partition, moves, parents):
    configs = work / "configs"
    fs_path = configs / f"fs_config-{partition}"
    contexts_path = configs / f"file_context-{partition}"
    fs = []
    contexts = []
    for line in fs_path.read_text().splitlines():
        path, separator, attributes = line.partition(" ")
        fs.append(relocated(path, moves) + separator + attributes)
    context_moves = [("/" + a, "/" + b) for a, b in moves]
    context_moves += [(re.escape(a), re.escape(b)) for a, b in context_moves.copy()]
    for line in contexts_path.read_text().splitlines():
        path, separator, label = line.partition(" ")
        contexts.append(relocated(path, context_moves) + separator + label)
    for parent in parents:
        path = parent.relative_to(work / partition).as_posix()
        if partition != "system":
            path = partition + "/" + path
        fs = [line for line in fs if line.split(" ", 1)[0] != path]
        contexts = [line for line in contexts if line.split(" ", 1)[0] != "/" + path]
        fs.append(f"{path} 0 0 755 capabilities=0x0")
        contexts.append(f"/{path} u:object_r:system_file:s0")
    fs_path.write_text("\n".join(fs) + "\n")
    contexts_path.write_text("\n".join(contexts) + "\n")


def update_omc_index(prism, moves):
    index = prism / "etc/omc_apks_list.txt"
    if index.exists():
        index.write_text("\n".join(relocated(line, moves)
                                   for line in index.read_text().splitlines()) + "\n")
    # These are staged OMC content indexes, not the source CSC databases.
    for path in sorted((prism / "etc/carriers").rglob("contents.db")):
        with closing(sqlite3.connect(path)) as database, database:
            for source, destination in moves:
                database.execute(
                    "UPDATE contents SET filePath = ? || substr(filePath, ?) "
                    "WHERE filePath = ? OR filePath LIKE ?",
                    (destination, len(source) + 1, source, source + "/%"),
                )
            if index.exists():
                database.execute("UPDATE contents SET fileSize = ? WHERE filePath = ?",
                                 (index.stat().st_size, "/prism/etc/omc_apks_list.txt"))


def make_removable(work, apktool):
    # PrePackageInstallerBase already scans these preload directories and
    # PrePackageInstaller applies the active CSC's enforceskippingpackages list.
    # Moving only the OMC app roots leaves telephony and CSC configuration alone.
    roots = [("prism", work / "prism", "preload/Common_app"),
             ("system", work / "system/system/carrier", "preload")]
    pending = []
    for partition, root, preload in roots:
        for name in ("app", "priv-app"):
            source = root / name
            if not source.is_dir():
                continue
            destination = root / preload / name
            if destination.exists():
                raise ValueError(f"OMC preload destination already exists: {destination}")
            apks = sorted([*source.rglob("*.apk"), *source.rglob("*.apk.gz")])
            if apks:
                pending.append((partition, root, source, destination, apks))
    if not pending:
        print("OMC apps: no system applications to migrate")
        return

    migration_path = work / "system/system/etc/system_to_data_app_list.xml"
    migration = ET.parse(migration_path) if migration_path.exists() else ET.ElementTree(ET.Element("packages"))
    if migration.getroot().tag != "packages":
        raise ValueError(f"Unexpected migration list format: {migration_path}")
    packages = {entry.get("name") for entry in migration.getroot().findall("package")}
    new_packages = set()
    # Decode only manifests; APKs and their original Samsung/carrier signatures
    # are preserved. Read all package names before changing the staged layout.
    with tempfile.TemporaryDirectory(prefix="omc-manifests-") as temporary:
        for _, _, _, _, apks in pending:
            for apk in apks:
                output = Path(temporary) / "manifest"
                input_apk = apk
                if apk.name.endswith(".gz"):
                    input_apk = Path(temporary) / "decompressed.apk"
                    with gzip.open(apk, "rb") as compressed, input_apk.open("wb") as unpacked:
                        shutil.copyfileobj(compressed, unpacked)
                subprocess.run([apktool, "d", "--only-manifest", "--no-src", "--no-assets",
                                "-f", "-q", "-o", str(output), str(input_apk)], check=True)
                manifest = ET.parse(output / "AndroidManifest.xml").getroot()
                package = manifest.get("package", "")
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+", package):
                    raise ValueError(f"Invalid OMC package name in {apk}: {package}")
                if manifest.get("split"):
                    raise ValueError(f"Split OMC apps require a split-aware preload installer: {apk}")
                new_packages.add(package)

    for partition, root, source, destination, apks in pending:
        destination.parent.mkdir(parents=True, exist_ok=True)
        old = source.relative_to(work / partition).as_posix()
        new = destination.relative_to(work / partition).as_posix()
        if partition != "system":
            old, new = partition + "/" + old, partition + "/" + new
        shutil.move(str(source), str(destination))
        parents = []
        parent = destination.parent
        while parent != root:
            parents.append(parent)
            parent = parent.parent
        update_metadata(work, partition, [(old, new)], parents)
        if partition == "prism":
            update_omc_index(root, [("/" + old, "/" + new)])
        print(f"OMC apps: /{old} -> /{new} ({len(apks)} APKs)")

    # Keep data during a ROM update when a formerly scanned system app moves
    # into /data/app. Samsung's package manager consumes this existing list.
    for package in sorted(new_packages - packages):
        ET.SubElement(migration.getroot(), "package", name=package)
    ET.indent(migration, space="    ")
    migration_path.write_bytes(ET.tostring(migration.getroot(), encoding="utf-8", xml_declaration=True) + b"\n")
    print(f"OMC apps: {len(new_packages)} packages prepared as removable preloads")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("work_dir", type=Path)
    parser.add_argument("apktool")
    arguments = parser.parse_args()
    make_removable(arguments.work_dir, arguments.apktool)


if __name__ == "__main__":
    main()
