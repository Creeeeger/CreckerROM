#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


def run(command: list[str], *, capture: bool = False) -> str:
    result = subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout if capture else ""


def parse_metadata_text(text: str) -> dict[str, object]:
    # lpdump JSON does not carry every lpmake input we need, so parse the text
    # view for metadata geometry and readonly partition attributes.
    max_size_match = re.search(r"^Metadata max size:\s+(\d+) bytes$", text, re.MULTILINE)
    slots_match = re.search(r"^Metadata slot count:\s+(\d+)$", text, re.MULTILINE)
    flags_match = re.search(r"^Header flags:\s+(.+)$", text, re.MULTILINE)
    if not max_size_match or not slots_match:
        raise ValueError("Unable to parse super metadata size/slot count")

    attributes: dict[str, str] = {}
    in_partitions = False
    current_name: str | None = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line == "Partition table:":
            in_partitions = True
            current_name = None
            continue
        if line == "Super partition layout:":
            in_partitions = False
            current_name = None
            continue
        if not in_partitions:
            continue
        if line.startswith("Name: "):
            current_name = line.split(":", 1)[1].strip()
        elif current_name and line.startswith("Attributes: "):
            value = line.split(":", 1)[1].strip()
            attributes[current_name] = "readonly" if "readonly" in value.split(",") else "none"

    return {
        "metadata_size": int(max_size_match.group(1)),
        "metadata_slots": int(slots_match.group(1)),
        "header_flags": flags_match.group(1).strip() if flags_match else "none",
        "attributes": attributes,
    }


def normalize_layout(raw_json: dict[str, object], text: str, source: Path) -> dict[str, object]:
    parsed = parse_metadata_text(text)
    partitions = []
    for partition in raw_json.get("partitions", []):
        name = str(partition["name"])
        partitions.append(
            {
                "name": name,
                "group": str(partition["group_name"]),
                "size": int(partition["size"]),
                "attributes": parsed["attributes"].get(name, "readonly"),
            }
        )

    groups = []
    for group in raw_json.get("groups", []):
        groups.append(
            {
                "name": str(group["name"]),
                "maximum_size": int(group.get("maximum_size", 0)),
            }
        )

    devices = []
    for device in raw_json.get("block_devices", []):
        devices.append(
            {
                "name": str(device["name"]),
                "size": int(device["size"]),
                "block_size": int(device.get("block_size", 4096)),
                "alignment": int(device.get("alignment", 0)),
                "alignment_offset": int(device.get("alignment_offset", 0)),
            }
        )

    if not partitions or not devices:
        raise ValueError("Super metadata contains no partitions or block devices")

    return {
        "version": 1,
        "source": str(source),
        "source_sha256": sha256(source),
        "super_name": str(raw_json.get("super_device", {}).get("name", devices[0]["name"])),
        "metadata_size": parsed["metadata_size"],
        "metadata_slots": parsed["metadata_slots"],
        "header_flags": parsed["header_flags"],
        "partitions": partitions,
        "groups": groups,
        "block_devices": devices,
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_layout(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def command_unpack(args: argparse.Namespace) -> None:
    args.output_dir.mkdir(parents=True, exist_ok=True)
    # Save a normalized layout snapshot before unpacking so later build/verify
    # steps do not depend on lpdump output ordering.
    raw_json = json.loads(run([str(args.lpdump), "--json", str(args.super_image)], capture=True))
    text = run([str(args.lpdump), "--all", str(args.super_image)], capture=True)
    layout = normalize_layout(raw_json, text, args.super_image)
    args.layout.write_text(json.dumps(layout, indent=2) + "\n", encoding="utf-8")

    run([str(args.lpunpack), str(args.super_image), str(args.output_dir)])
    missing = [
        partition["name"]
        for partition in layout["partitions"]
        if not (args.output_dir / f"{partition['name']}.img").is_file()
    ]
    if missing:
        raise RuntimeError(f"lpunpack did not create: {', '.join(missing)}")


def device_argument(device: dict[str, object]) -> str:
    value = f"{device['name']}:{device['size']}"
    alignment = int(device.get("alignment", 0))
    offset = int(device.get("alignment_offset", 0))
    if alignment or offset:
        value += f":{alignment}:{offset}"
    return value


def build_command(layout: dict[str, object], images_dir: Path, output: Path, lpmake: Path) -> list[str]:
    command = [
        str(lpmake),
        "--metadata-size",
        str(layout["metadata_size"]),
        "--metadata-slots",
        str(layout["metadata_slots"]),
        "--super-name",
        str(layout["super_name"]),
    ]
    if "virtual_ab_device" in str(layout.get("header_flags", "")).lower():
        command.append("--virtual-ab")

    for device in layout["block_devices"]:
        command.extend(["--device", device_argument(device)])
    for group in layout["groups"]:
        if group["name"] == "default":
            continue
        command.extend(["--group", f"{group['name']}:{group['maximum_size']}"])
    for partition in layout["partitions"]:
        image = images_dir / f"{partition['name']}.img"
        if not image.is_file():
            raise FileNotFoundError(image)
        actual_size = image.stat().st_size
        expected_size = int(partition["size"])
        # Rollback super images must preserve logical partition sizes exactly;
        # changing them would require changing the stored LP metadata too.
        if actual_size != expected_size:
            raise ValueError(
                f"{image.name} size changed: expected {expected_size}, got {actual_size}"
            )
        command.extend(
            [
                "--partition",
                f"{partition['name']}:{partition['attributes']}:{expected_size}:{partition['group']}",
                "--image",
                f"{partition['name']}={image}",
            ]
        )

    command.extend(["--sparse", "--output", str(output)])
    return command


def command_build(args: argparse.Namespace) -> None:
    layout = load_layout(args.layout)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        args.output.unlink()
    run(build_command(layout, args.images_dir, args.output, args.lpmake))


def comparable(layout: dict[str, object]) -> dict[str, object]:
    # Verification ignores source path/hash and compares only flash-relevant LP
    # layout fields that must round-trip through lpmake.
    return {
        "super_name": layout["super_name"],
        "metadata_size": layout["metadata_size"],
        "metadata_slots": layout["metadata_slots"],
        "partitions": sorted(layout["partitions"], key=lambda item: item["name"]),
        "groups": sorted(layout["groups"], key=lambda item: item["name"]),
        "block_devices": sorted(layout["block_devices"], key=lambda item: item["name"]),
    }


def command_verify(args: argparse.Namespace) -> None:
    expected = load_layout(args.layout)
    raw_json = json.loads(run([str(args.lpdump), "--json", str(args.super_image)], capture=True))
    text = run([str(args.lpdump), "--all", str(args.super_image)], capture=True)
    actual = normalize_layout(raw_json, text, args.super_image)
    if comparable(expected) != comparable(actual):
        raise RuntimeError("Rebuilt super metadata does not match the source layout")
    print("Super metadata matches the source layout.")


def command_values(args: argparse.Namespace) -> None:
    layout = load_layout(args.layout)
    # Shell rollback code consumes these values to export TARGET_*_PARTITION_SIZE
    # variables for the shared AVB signer.
    if args.kind == "partitions":
        for partition in layout["partitions"]:
            print(f"{partition['name']}\t{partition['size']}")
    elif args.kind == "super-size":
        print(layout["block_devices"][0]["size"])
    elif args.kind == "group-size":
        sizes = [group["maximum_size"] for group in layout["groups"] if group["name"] != "default"]
        print(max(sizes, default=0))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Unpack and rebuild super.img while preserving its logical-partition metadata"
    )
    subparsers = result.add_subparsers(dest="command", required=True)

    unpack = subparsers.add_parser("unpack")
    unpack.add_argument("--super-image", type=Path, required=True)
    unpack.add_argument("--output-dir", type=Path, required=True)
    unpack.add_argument("--layout", type=Path, required=True)
    unpack.add_argument("--lpdump", type=Path, required=True)
    unpack.add_argument("--lpunpack", type=Path, required=True)
    unpack.set_defaults(func=command_unpack)

    build = subparsers.add_parser("build")
    build.add_argument("--layout", type=Path, required=True)
    build.add_argument("--images-dir", type=Path, required=True)
    build.add_argument("--output", type=Path, required=True)
    build.add_argument("--lpmake", type=Path, required=True)
    build.set_defaults(func=command_build)

    verify = subparsers.add_parser("verify")
    verify.add_argument("--layout", type=Path, required=True)
    verify.add_argument("--super-image", type=Path, required=True)
    verify.add_argument("--lpdump", type=Path, required=True)
    verify.set_defaults(func=command_verify)

    values = subparsers.add_parser("values")
    values.add_argument("--layout", type=Path, required=True)
    values.add_argument("kind", choices=("partitions", "super-size", "group-size"))
    values.set_defaults(func=command_values)
    return result


def main() -> None:
    args = parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
