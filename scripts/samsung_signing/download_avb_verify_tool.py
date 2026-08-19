#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

"""Verify AVB on the sparse bytes Exynos LK writes after Odin download."""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

from avb_cli import avb_environment, read_footer_metadata
from download_signature_common import (
    download_signature_header,
    parse_download_signature_layout,
    write_download_signature,
)
from stage2_common import STAGE2_SIGNATURE_SIZE


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Verify AVB after normalizing the Samsung FullHashSig field exactly "
            "as Exynos LK does while receiving a sparse image"
        )
    )
    parser.add_argument("-i", "--input", required=True, type=Path)
    parser.add_argument("--avbtool", required=True, type=Path)
    parser.add_argument("--key", required=True, type=Path)
    args = parser.parse_args()

    for label, path in (("input", args.input), ("avbtool", args.avbtool), ("key", args.key)):
        if not path.is_file():
            parser.error(f"--{label} not found: {path}")

    layout = parse_download_signature_layout(args.input)
    metadata = read_footer_metadata(args.input, args.avbtool, args.input.stem)
    if metadata is None:
        parser.error(f"{args.input} has no AVB footer")
    partition = str(metadata["partition_name"])

    with tempfile.TemporaryDirectory(prefix="crecker_download_avb_") as directory:
        normalized = Path(directory) / f"{partition}{args.input.suffix or '.img'}"
        # These images can be several GiB. Prefer a CoW clone while retaining a
        # portable fallback through cp itself when reflinks are unavailable.
        subprocess.run(
            ["cp", "--reflink=auto", "--", str(args.input), str(normalized)],
            check=True,
        )
        header = download_signature_header(
            layout.rp_count,
            layout.sign_type,
            layout.key_type,
            layout.key_index,
        )
        write_download_signature(
            normalized,
            layout,
            header,
            b"\x00" * STAGE2_SIGNATURE_SIZE,
        )
        print(f"Archive image: {args.input}")
        print(f"Partition: {partition}")
        print(
            "LK normalization: FullHashSig "
            f"0x{layout.signature_offset:X}.."
            f"0x{layout.signature_offset + STAGE2_SIGNATURE_SIZE:X} -> zero"
        )
        subprocess.run(
            [
                sys.executable,
                str(args.avbtool),
                "verify_image",
                "--image",
                str(normalized),
                "--key",
                str(args.key),
            ],
            check=True,
            env=avb_environment(),
        )
    print("Normalized post-download AVB verification passed")


if __name__ == "__main__":
    main()
