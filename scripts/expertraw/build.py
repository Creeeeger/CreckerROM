#!/usr/bin/env python3
# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later
"""Download pinned Samsung APKs and build the Android 15 Expert RAW port."""

import argparse
import hashlib
import json
import subprocess
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from apk import repack

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PACKAGE = "com.samsung.android.app.galaxyraw"


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_source(path, release):
    if path.stat().st_size != release["bytes"] or sha256(path) != release["sha256"]:
        raise ValueError(f"Source APK does not match the pinned Samsung release: {path}")


def store_source(release, cache, supplied=None):
    if supplied:
        verify_source(supplied, release)
        return supplied
    path = cache / f"ExpertRAW-{release['version']}-{release['version_code']}.apk"
    if path.exists():
        verify_source(path, release)
        return path
    params = {
        "appId": PACKAGE, "deviceId": release["device_id"],
        "sdkVer": release["sdk"], "oneUiVersion": release["oneui"],
        "mcc": "262", "mnc": "01", "csc": "EUX",
        "extuk": "0191d6627f38685f", "pd": "0",
    }
    endpoint = "https://vas.samsungapps.com/stub/stubDownload.as?"
    with urllib.request.urlopen(endpoint + urllib.parse.urlencode(params), timeout=60) as response:
        result = ET.fromstring(response.read())
    if result.findtext("versionCode") != str(release["version_code"]):
        raise ValueError(
            f"Galaxy Store now serves {result.findtext('versionName')} for {release['device_id']}; "
            f"the patches require {release['version']}. Supply the pinned APK with --source "
            "or --backend-source; review the patches before updating release.json."
        )
    url = result.findtext("downloadURI", "")
    if urllib.parse.urlsplit(url).scheme != "https":
        raise ValueError("Galaxy Store did not supply an HTTPS download")
    cache.mkdir(parents=True, exist_ok=True)
    # Fresh CDN URL on every cache miss. Never store expiring links in the repository.
    with tempfile.NamedTemporaryFile(dir=cache, suffix=".part", delete=False) as output:
        partial = Path(output.name)
        try:
            print(f"Downloading Samsung Expert RAW {release['version']} ({release['bytes'] // 1048576} MiB)", flush=True)
            with urllib.request.urlopen(url, timeout=120) as response:
                while block := response.read(1024 * 1024):
                    output.write(block)
            output.close()
            verify_source(partial, release)
            partial.replace(path)
        finally:
            partial.unlink(missing_ok=True)
    return path


def make_profile(source, release, configuration, destination):
    with zipfile.ZipFile(source) as original:
        root = ET.fromstring(original.read(release["profile_asset"]))
    for element in list(root):
        name = element.get("name")
        if name in configuration["remove"]:
            root.remove(element)
        elif name in configuration["set"]:
            element.set("value", configuration["set"][name])
        for attribute, value in configuration.get("attributes", {}).get(name, {}).items():
            element.set(attribute, value)
    # Some optional flags are omitted by the stock flagship profile.
    present = {element.get("name") for element in root}
    for name, value in configuration["set"].items():
        if name not in present:
            ET.SubElement(root, "local", name=name, value=value)
    ET.indent(root, space="    ")
    ET.ElementTree(root).write(destination, encoding="utf-8", xml_declaration=True)


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def build(args):
    release = json.loads((HERE / "release.json").read_text())
    configuration = json.loads(args.profile.read_text())
    source = store_source(release, args.cache, args.source)
    backend = store_source(release["backend"], args.cache, args.backend_source)
    tools = args.tools / "bin"
    for name in ["baksmali", "smali", "signapk", "zipalign"]:
        if not (tools / name).is_file():
            raise ValueError(f"Missing ROM build tool {tools / name}; run the repository tool setup first")
    for path in [args.cert, args.key]:
        if not path.is_file():
            raise ValueError(f"Missing ROM signing file: {path}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="expertraw-", dir=args.output.parent) as folder:
        work = Path(folder)
        dex = work / "classes3.dex"
        with zipfile.ZipFile(source) as original:
            data = original.read("classes3.dex")
        if data[:8] != b"dex\n039\0":
            raise ValueError("Unexpected source DEX version; review the Android 15 port")
        dex.write_bytes(data)
        print("Patching Android APIs, S26 Ultra profile selection and S20+ lens sizes", flush=True)
        # API 28 selects DEX 039. Do not emit DEX 041 container bytecode on Android 15.
        run(tools / "baksmali", "-JXmx2048M", "d", "--api", "28", "-j", "4", "-l",
            "--debug-info", "false", "--accessor-comments", "false", "--sequential-labels",
            "-o", work / "smali_classes3", dex)
        run("patch", "--batch", "--fuzz=0", "-p1", "-i", HERE / "android15-y2s.patch", cwd=work)
        dex_dir = work / "dex"
        dex_dir.mkdir()
        run(tools / "smali", "-JXmx2048M", "a", "--api", "28", "-j", "4",
            "-o", dex_dir / "classes3.dex", work / "smali_classes3")
        profile = work / "galaxyraw-feature.xml"
        make_profile(source, release, configuration, profile)
        unsigned = work / "unsigned.apk"
        repack(source, unsigned, dex_dir, profile, backend=backend,
               native_files=release["backend"]["native_files"])
        signed = work / "ExpertRAW.apk"
        run(tools / "signapk", "-JXmx2048M", "-a", "16384", "--min-sdk-version", "35",
            args.cert, args.key, unsigned, signed)
        run(tools / "zipalign", "-c", "4", signed)
        signed.replace(args.output)
    metadata = {
        "author": "Creeeeger",
        "version": release["version"], "version_code": release["version_code"],
        "sdk": 35, "profile": "m3q (S26 Ultra)", "device": "y2s",
        "source_sha256": release["sha256"], "backend_sha256": release["backend"]["sha256"],
        "backend_version": release["backend"]["version"],
        "apk_sha256": sha256(args.output),
    }
    args.output.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Built {args.output}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Offline APK matching release.json")
    parser.add_argument("--backend-source", type=Path, help="Offline APK for the compatible native backend")
    parser.add_argument("--cache", type=Path, default=ROOT / "out/downloads/expertraw")
    parser.add_argument("--tools", type=Path, default=ROOT / "out/tools")
    parser.add_argument("--profile", type=Path, default=ROOT / "target/y2s/patches/expertraw/profile.json")
    parser.add_argument("--cert", type=Path, default=ROOT / "security/creckerrom_platform.x509.pem")
    parser.add_argument("--key", type=Path, default=ROOT / "security/creckerrom_platform.pk8")
    parser.add_argument("--output", type=Path, default=ROOT / "out/expertraw/y2s/ExpertRAW.apk")
    try:
        build(parser.parse_args())
    except (OSError, ValueError, subprocess.CalledProcessError, ET.ParseError) as error:
        parser.exit(1, f"Expert RAW build failed: {error}\n")
