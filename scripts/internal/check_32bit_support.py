#!/usr/bin/env python3
# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later

"""Validate ARM32 launchers and match OEM public library lists to installed ABIs."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys


def require_elf(path: Path, bits: int) -> None:
    with path.open("rb") as stream:
        header = stream.read(20)
    expected = (40 if bits == 32 else 183).to_bytes(2, "little")
    if header[:6] != b"\x7fELF" + bytes([bits // 32, 1]) or header[18:20] != expected:
        raise ValueError(f"Expected ARM{bits} ELF: {path}")


def require_launchers(work: Path) -> None:
    fs = {}
    for line in (work / "configs/fs_config-system").read_text().splitlines():
        fields = line.split()
        if len(fields) >= 4:
            fs[fields[0]] = fields[1:4]
    contexts = {}
    for line in (work / "configs/file_context-system").read_text().splitlines():
        fields = line.split()
        if len(fields) == 2:
            contexts[fields[0]] = fields[1]
    required = {
        "system/bin/app_process32": "zygote_exec",
        "system/bin/bootstrap/linker": "system_linker_exec",
        "system/bin/boringssl_self_test32": "boringssl_self_test_exec",
    }
    for relative, label in required.items():
        require_elf(work / "system" / relative, 32)
        if relative not in fs or int(fs[relative][2], 8) & 0o111 != 0o111:
            raise ValueError(f"Missing executable image metadata: /{relative}")
        if contexts.get("/" + re.escape(relative)) != f"u:object_r:{label}:s0":
            raise ValueError(f"Incorrect SELinux image label for /{relative}")


def require_multilib_apexes(work: Path) -> None:
    payload = Path(__file__).resolve().parents[2] / "prebuilts/samsung/r11sxxx_32bit/payload.json"
    manifest = json.loads(payload.read_text())
    # ART's 32-bit zygote also loads providers from other APEXes, including
    # libadbconnection_client.so from adbd. Check the final staged packages
    # after all ROM modules have run, not just the initial donor payload.
    for name, expected in manifest["apex"].items():
        path = work / "system/system/apex" / name
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != expected["donor_sha256"]:
            raise ValueError(f"Missing matching ARM32 runtime APEX: {name}")


def installed_library(system: Path, name: str, bits: int) -> bool:
    path = system / ("lib" if bits == 32 else "lib64") / name
    seen = set()
    while path.is_symlink():
        if path in seen:
            raise ValueError(f"Public library symlink cycle: {path}")
        seen.add(path)
        target = path.readlink()
        if target.is_absolute():
            if not str(target).startswith("/system/"):
                raise ValueError(f"Cannot validate public library symlink: {path} -> {target}")
            path = system / str(target).removeprefix("/system/")
        else:
            path = Path(os.path.normpath(path.parent / target))
    if not path.is_file():
        return False
    require_elf(path, bits)
    return True


def public_library_changes(work: Path) -> tuple[dict[Path, str], list[str]]:
    system = work / "system/system"
    changes = {}
    findings = []
    # The core NDK list is a platform requirement and must not be reduced to
    # hide missing runtime libraries. Only OEM extension lists are normalized.
    for path in sorted((system / "etc").glob("public.libraries-*.txt")):
        output = []
        for line in path.read_text().splitlines():
            entry, separator, comment = line.partition("#")
            fields = entry.split()
            if not fields:
                output.append(line)
                continue
            name, *flags = fields
            bitness = [flag for flag in flags if flag in ("32", "64")]
            if len(bitness) > 1 or any(flag not in ("32", "64", "nopreload") for flag in flags):
                raise ValueError(f"Invalid public library declaration: {path}: {line}")
            requested = {int(bitness[0])} if bitness else {32, 64}
            available = {bits for bits in requested if installed_library(system, name, bits)}
            if available == requested:
                output.append(line)
            elif not available:
                findings.append(f"{path.name}: remove absent {name}")
            else:
                bits = str(next(iter(available)))
                updated = " ".join([name, bits, *[flag for flag in flags if flag == "nopreload"]])
                output.append(updated + (" #" + comment if separator else ""))
                findings.append(f"{path.name}: restrict {name} to {bits}-bit")
        updated = "\n".join(output) + ("\n" if output else "")
        # Preserve untouched files, including their original final newline.
        if output != path.read_text().splitlines():
            changes[path] = updated
    return changes, findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("work_dir", type=Path)
    parser.add_argument("--fix-public-libraries", action="store_true")
    args = parser.parse_args()
    try:
        require_launchers(args.work_dir)
        require_multilib_apexes(args.work_dir)
        changes, findings = public_library_changes(args.work_dir)
        if findings and not args.fix_public_libraries:
            print("\n".join(findings), file=sys.stderr)
            return 1
        for path, contents in changes.items():
            path.write_text(contents)
        print(f"ARM32 launchers, multilib APEXes and image metadata verified; corrected {len(findings)} OEM public library declarations.")
    except (OSError, ValueError) as error:
        print(f"32-bit support validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
