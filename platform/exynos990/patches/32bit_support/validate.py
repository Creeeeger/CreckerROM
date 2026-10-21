#!/usr/bin/env python3
# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later

"""Check the committed S23 FE ARM32 prebuilts before changing a ROM."""

import hashlib
import json
from pathlib import Path
import sys


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_arm32(path: Path) -> None:
    with path.open("rb") as stream:
        header = stream.read(20)
    if header[:6] != b"\x7fELF\x01\x01" or header[18:20] != b"\x28\x00":
        raise ValueError(f"Expected an ARM32 ELF binary: {path}")


def validate(module: Path, work: Path) -> None:
    manifest = json.loads((module / "payload.json").read_text())
    system = work / "system/system"
    props = dict(
        line.split("=", 1)
        for line in (system / "build.prop").read_text().splitlines()
        if "=" in line and not line.startswith("#")
    )
    if props.get("ro.build.version.sdk") != "35" or props.get("ro.build.version.oneui") != "70000":
        raise ValueError("The ARM32 donor requires Android 15 / One UI 7; update the donor for this base.")

    installed = {
        path.relative_to(module).as_posix()
        for path in (module / "system").rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if installed != set(manifest["files"]):
        raise ValueError("ARM32 prebuilt files do not match the pinned payload manifest.")

    for relative, expected in manifest["files"].items():
        path = module / relative
        if "symlink" in expected:
            if not path.is_symlink() or str(path.readlink()) != expected["symlink"]:
                raise ValueError(f"Incorrect ARM32 runtime symlink: {relative}")
        else:
            if path.is_symlink() or sha256(path) != expected["sha256"]:
                raise ValueError(f"ARM32 payload checksum mismatch: {relative}")
            if path.suffix == ".so" or path.name in ("app_process32", "boringssl_self_test32"):
                require_arm32(path)

    for relative, expected in manifest["prerequisites"].items():
        path = system / relative.removeprefix("system/")
        if sha256(path) != expected:
            raise ValueError(f"Missing matching multilib prerequisite: {relative}; apply the ROM patches first.")

    for name, expected in manifest["apex"].items():
        # Accept the stock base or this module's output, allowing reapplication.
        # A new mainline release needs a matching, signed multilib donor rather
        # than an unverified downgrade of the running 64-bit runtime.
        if sha256(system / "apex" / name) not in expected.values():
            raise ValueError(f"Incompatible base APEX: {name}; refresh the ARM32 donor for this firmware.")

    for name, service in [
        ("init.zygote64.rc", "service zygote /system/bin/app_process64"),
        ("init.zygote64_32.rc", "service zygote_secondary /system/bin/app_process32"),
    ]:
        if service not in (system / "etc/init/hw" / name).read_text():
            raise ValueError(f"Missing dual-zygote init service: {name}")

    require_arm32(work / "vendor/lib/egl/libGLES_mali.so")
    require_arm32(system / "bin/bootstrap/linker")
    if not (system / "bin/linker").is_symlink():
        raise ValueError("The ARM32 Bionic linker is missing; apply the ROM patches first.")


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: validate.py <prebuilt directory> <work directory>", file=sys.stderr)
        return 1
    try:
        validate(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError, KeyError) as error:
        print(f"32-bit app support: {error}", file=sys.stderr)
        return 1
    print("32-bit app support: payload, mainline versions, init services and Mali driver verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
