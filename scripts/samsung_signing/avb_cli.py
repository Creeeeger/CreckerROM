#!/usr/bin/env python3
"""Stable command-line integration for AVB metadata operations."""

from __future__ import annotations

import argparse
import ast
import base64
import os
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO_DIR = Path(__file__).resolve().parents[2]
OPENSSL_COMPAT_DIR = REPO_DIR / "scripts" / "internal"


def avb_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["PATH"] = os.pathsep.join(
        [str(OPENSSL_COMPAT_DIR), environment.get("PATH", "")]
    )
    return environment


def parse_quoted(value: str) -> str:
    try:
        parsed = ast.literal_eval(value)
    except (SyntaxError, ValueError):
        return value.strip("'")
    return parsed if isinstance(parsed, str) else str(parsed)


def parse_size(value: str) -> int:
    return int(value.split()[0])


def parse_avb_info(text: str) -> dict[str, Any]:
    # avbtool exposes several fields only as text. Keep this parser narrow to
    # the stable lines consumed by the shell integration.
    metadata: dict[str, Any] = {"footer": False, "descriptors": []}
    current: dict[str, Any] | None = None
    in_descriptors = False

    top_level_fields = {
        "Header Block": ("header_block_size", parse_size),
        "Authentication Block": ("authentication_block_size", parse_size),
        "Auxiliary Block": ("auxiliary_block_size", parse_size),
        "Algorithm": ("algorithm", str),
        "Rollback Index": ("rollback_index", int),
        "Flags": ("flags", int),
        "Rollback Index Location": ("rollback_index_location", int),
        "Release String": ("release_string", parse_quoted),
    }

    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped == "--":
            continue
        if stripped.startswith("Footer version:"):
            metadata["footer"] = True
            continue
        if stripped == "Descriptors:":
            in_descriptors = True
            current = None
            continue

        if not in_descriptors and ":" in stripped:
            key, value = (part.strip() for part in stripped.split(":", 1))
            field = top_level_fields.get(key)
            if field is not None:
                name, converter = field
                metadata[name] = converter(value)
            continue

        if not in_descriptors:
            continue

        if raw_line.startswith("    ") and not raw_line.startswith("      "):
            if stripped.startswith("Prop: "):
                key, value = stripped[6:].split(" -> ", 1)
                metadata["descriptors"].append(
                    {"kind": "prop", "key": key, "value": parse_quoted(value)}
                )
                current = None
                continue

            descriptor_names = {
                "Hash descriptor:": "hash",
                "Hashtree descriptor:": "hashtree",
                "Chain Partition descriptor:": "chain",
                "Kernel Cmdline descriptor:": "kernel_cmdline",
            }
            kind = descriptor_names.get(stripped)
            if kind is not None:
                current = {"kind": kind}
                metadata["descriptors"].append(current)
            else:
                current = None
            continue

        if current is None or ":" not in stripped:
            continue

        key, value = (part.strip() for part in stripped.split(":", 1))
        descriptor_fields = {
            "Partition Name": ("partition_name", str),
            "Hash Algorithm": ("hash_algorithm", str),
            "Rollback Index Location": ("rollback_index_location", int),
            "Flags": ("flags", int),
            "FEC num roots": ("fec_num_roots", int),
            "Kernel Cmdline": ("kernel_cmdline", parse_quoted),
        }
        field = descriptor_fields.get(key)
        if field is not None:
            name, converter = field
            current[name] = converter(value)

    required = {
        "header_block_size",
        "authentication_block_size",
        "auxiliary_block_size",
        "algorithm",
        "rollback_index",
        "flags",
        "rollback_index_location",
        "release_string",
    }
    missing = sorted(required.difference(metadata))
    if missing:
        raise ValueError(f"Incomplete avbtool info_image output: {', '.join(missing)}")
    return metadata


def read_avb_info(
    avbtool: Path, image: Path, *, quiet: bool = False
) -> dict[str, Any]:
    process = subprocess.run(
        [sys.executable, str(avbtool), "info_image", "--image", str(image)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE if quiet else None,
        text=True,
        env=avb_environment(),
    )
    return parse_avb_info(process.stdout)


def read_footer_metadata(
    image: Path, avbtool: Path, fallback_partition: str
) -> dict[str, object] | None:
    try:
        metadata = read_avb_info(avbtool, image, quiet=True)
    except subprocess.CalledProcessError:
        return None
    if not metadata["footer"]:
        return None

    # Odin component re-signing only needs the footer descriptor that controls
    # avbtool add_hash_footer/add_hashtree_footer replay.
    result: dict[str, object] = {
        "partition_name": fallback_partition,
        "partition_size": image.stat().st_size,
        "kind": "hash",
        "rollback_index": metadata["rollback_index"],
        "rollback_index_location": metadata["rollback_index_location"],
        "hash_algorithm": "sha256",
        "flags": 0,
        "fec_num_roots": 0,
    }
    for descriptor in metadata["descriptors"]:
        if descriptor["kind"] in {"hash", "hashtree"}:
            result.update(descriptor)
            break
    return result


def write_records(metadata: dict[str, Any]) -> None:
    print(f"meta_algorithm\t{metadata['algorithm']}")
    print(f"meta_rollback_index\t{metadata['rollback_index']}")
    print(f"meta_rollback_index_location\t{metadata['rollback_index_location']}")
    print(f"meta_release_string\t{metadata['release_string']}")
    for descriptor in metadata["descriptors"]:
        kind = descriptor["kind"]
        if kind == "prop":
            print(f"prop\t{descriptor['key']}\t{descriptor['value']}")
        elif kind in {"hash", "hashtree"}:
            print(f"{kind}\t{descriptor.get('partition_name', '')}")
        elif kind == "chain":
            print(
                f"chain\t{descriptor.get('partition_name', '')}\t"
                f"{descriptor.get('rollback_index_location', 0)}"
            )
        elif kind == "kernel_cmdline":
            encoded = base64.b64encode(
                descriptor.get("kernel_cmdline", "").encode("utf-8")
            ).decode("ascii")
            print(f"kernel_cmdline\t{descriptor.get('flags', 0)}\t{encoded}")


def patch_kernel_cmdline_flags(image: Path, flags: list[int]) -> None:
    data = bytearray(image.read_bytes())
    if data[:4] != b"AVB0":
        raise ValueError("Generated image is not a vbmeta image")

    # avbtool can generate kernel cmdline descriptors but does not expose their
    # stored flags on creation, so patch the descriptor headers directly.
    authentication_size = struct.unpack_from(">Q", data, 12)[0]
    descriptors_offset = struct.unpack_from(">Q", data, 96)[0]
    descriptors_size = struct.unpack_from(">Q", data, 104)[0]
    cursor = 256 + authentication_size + descriptors_offset
    end = cursor + descriptors_size
    flag_index = 0
    if end > len(data):
        raise ValueError("Descriptor block extends beyond the generated image")

    while cursor < end:
        if cursor + 16 > end:
            raise ValueError("Truncated AVB descriptor header")
        tag, following = struct.unpack_from(">QQ", data, cursor)
        if tag == 3:
            if flag_index >= len(flags):
                raise ValueError("Generated more kernel cmdline descriptors than requested")
            struct.pack_into(">I", data, cursor + 16, flags[flag_index])
            flag_index += 1
        next_cursor = cursor + 16 + following
        if next_cursor > end:
            raise ValueError("AVB descriptor extends beyond the descriptor block")
        cursor = next_cursor

    if flag_index != len(flags):
        raise ValueError("Generated fewer kernel cmdline descriptors than requested")
    image.write_bytes(data)


def make_kernel_cmdline_image(
    avbtool: Path, input_path: Path, output_path: Path
) -> None:
    entries: list[tuple[int, str]] = []
    for raw_line in input_path.read_text(encoding="utf-8").splitlines():
        if not raw_line:
            continue
        flags, encoded = raw_line.split("\t", 1)
        entries.append((int(flags), base64.b64decode(encoded).decode("utf-8")))

    command = [
        sys.executable,
        str(avbtool),
        "make_vbmeta_image",
        "--output",
        str(output_path),
        "--algorithm",
        "NONE",
    ]
    for _, cmdline in entries:
        command.extend(["--kernel_cmdline", cmdline])
    subprocess.run(command, check=True, env=avb_environment())
    patch_kernel_cmdline_flags(output_path, [flags for flags, _ in entries])

    parsed = read_avb_info(avbtool, output_path)
    actual = [
        (descriptor.get("flags", 0), descriptor.get("kernel_cmdline", ""))
        for descriptor in parsed["descriptors"]
        if descriptor["kind"] == "kernel_cmdline"
    ]
    if actual != entries:
        raise ValueError("Kernel cmdline descriptor round-trip validation failed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--avbtool", required=True, type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name in ("records", "flags", "kind", "footer", "trailer"):
        command = subparsers.add_parser(name)
        command.add_argument("--image", required=True, type=Path)
        if name == "footer":
            command.add_argument("--fallback-partition", required=True)

    make = subparsers.add_parser("make-kernel-cmdline-image")
    make.add_argument("--input", required=True, type=Path)
    make.add_argument("--output", required=True, type=Path)

    args = parser.parse_args()
    if args.command == "make-kernel-cmdline-image":
        make_kernel_cmdline_image(args.avbtool, args.input, args.output)
        return

    if args.command == "footer":
        metadata = read_footer_metadata(
            args.image, args.avbtool, args.fallback_partition
        )
        if metadata is None:
            return
        flags = int(metadata.get("flags", 0))
        print(
            "\t".join(
                [
                    str(metadata["kind"]),
                    str(metadata["partition_name"]),
                    str(metadata["hash_algorithm"]),
                    str(metadata["rollback_index"]),
                    str(metadata["rollback_index_location"]),
                    str(int(bool(flags & 1))),
                    str(int(bool(flags & 2))),
                    str(int(int(metadata.get("fec_num_roots", 0)) == 0)),
                ]
            )
        )
        return

    try:
        metadata = read_avb_info(
            args.avbtool, args.image, quiet=args.command == "kind"
        )
    except subprocess.CalledProcessError:
        if args.command == "kind":
            return
        raise
    if args.command == "records":
        write_records(metadata)
    elif args.command == "flags":
        print(metadata["flags"])
    elif args.command == "kind" and metadata["footer"]:
        for descriptor in metadata["descriptors"]:
            if descriptor["kind"] in {"hash", "hashtree"}:
                print(descriptor["kind"])
                break
    elif args.command == "trailer":
        expected_size = (
            metadata["header_block_size"]
            + metadata["authentication_block_size"]
            + metadata["auxiliary_block_size"]
        )
        actual_size = args.image.stat().st_size
        if actual_size > expected_size:
            trailer = args.image.read_bytes()[expected_size:]
            for marker in (b"SignerVer03", b"SignerVer02"):
                if marker in trailer:
                    print(
                        f"{expected_size}\t{actual_size - expected_size}\t"
                        f"{marker.decode('ascii')}"
                    )
                    break


if __name__ == "__main__":
    main()
