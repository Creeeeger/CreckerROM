#!/usr/bin/env python3
import argparse
import json
import logging
import os
import re
import sys

from soc_data import EXYNOS_DATA, LEGACY_SOCS

logger = logging.getLogger("sboot_splitter")
SPLIT_MANIFEST_NAME = "split_manifest.json"
TAIL_FILENAME = "__tail__.bin"
GAP_FILENAME_TEMPLATE = "__gap_{start:08x}_{end:08x}.bin"


def detect_soc_from_sboot(sboot_path: str) -> str:
    """
    Detects the SoC identifier from sboot.bin (for example EXYNOS9830),
    formatted like in the original image: title-case + trailing null byte.
    """
    with open(sboot_path, "rb") as f:
        data = f.read()

    pattern = re.compile(b"EXYNOS[0-9]+")
    matches = pattern.findall(data)
    if not matches:
        raise RuntimeError("Could not find an EXYNOSxxxx string in sboot.bin.")

    soc = f"{matches[0].decode('utf-8').title()}\0"
    return soc


def resolve_soc(sboot_path: str, soc_arg: str | None) -> str:
    """
    If --soc is provided, use it (and append \0 when missing).
    Otherwise detect the SoC automatically from sboot.bin.
    """
    if soc_arg:
        soc = soc_arg
        if not soc.endswith("\0"):
            soc += "\0"
        return soc

    soc = detect_soc_from_sboot(sboot_path)
    return soc


def split_sboot(sboot_path: str, soc: str, out_dir: str) -> None:
    if soc not in EXYNOS_DATA:
        raise RuntimeError(f"SoC not supported in EXYNOS_DATA: {soc!r}")

    splits = EXYNOS_DATA[soc].get("bootloader_splits")
    if not splits:
        raise RuntimeError(f"No bootloader_splits found for SoC {soc!r}.")

    ranges: list[tuple[str, str, int, int]] = []
    for part_name, params in splits.items():
        start = params["start"]
        end = params["end"]
        if end <= start:
            raise RuntimeError(f"Invalid range for {part_name}: start={start}, end={end}")

        filename = part_name
        if not os.path.splitext(filename)[1]:
            filename += ".bin"

        ranges.append((part_name, filename, start, end))

    ranges.sort(key=lambda item: item[2])

    for idx in range(len(ranges) - 1):
        cur_name, _, cur_start, cur_end = ranges[idx]
        next_name, _, next_start, _ = ranges[idx + 1]
        if cur_end > next_start:
            raise RuntimeError(
                f"Overlapping ranges: {cur_name} (0x{cur_start:X}-0x{cur_end:X}) "
                f"and {next_name} (from 0x{next_start:X})"
            )

    os.makedirs(out_dir, exist_ok=True)

    source_size = os.path.getsize(sboot_path)
    max_end = max(end for _, _, _, end in ranges)
    if source_size < max_end:
        raise RuntimeError(
            f"sboot.bin is too small: file has {source_size} bytes, "
            f"but split ranges extend to 0x{max_end:X} ({max_end} bytes)."
        )

    manifest_parts: list[dict] = []
    manifest_gaps: list[dict] = []

    with open(sboot_path, "rb") as sboot:
        for part_name, filename, start, end in ranges:
            size = end - start
            sboot.seek(start)
            chunk = sboot.read(size)
            if len(chunk) != size:
                raise RuntimeError(
                    f"Could not fully read {part_name}: expected {size} bytes, got {len(chunk)} bytes"
                )

            out_path = os.path.join(out_dir, filename)
            with open(out_path, "wb") as out:
                out.write(chunk)

            manifest_parts.append(
                {
                    "name": part_name,
                    "filename": filename,
                    "start": start,
                    "end": end,
                    "size": size,
                }
            )

            logger.info(
                "Written: %s (0x%X - 0x%X) => %d bytes",
                out_path, start, end, size
            )

        covered_until = 0
        for _, _, start, end in ranges:
            if start > covered_until:
                gap_size = start - covered_until
                gap_filename = GAP_FILENAME_TEMPLATE.format(start=covered_until, end=start)
                sboot.seek(covered_until)
                gap_data = sboot.read(gap_size)
                if len(gap_data) != gap_size:
                    raise RuntimeError(
                        f"Could not fully read gap area: expected {gap_size} bytes, "
                        f"got {len(gap_data)} bytes"
                    )

                gap_path = os.path.join(out_dir, gap_filename)
                with open(gap_path, "wb") as out:
                    out.write(gap_data)

                manifest_gaps.append(
                    {
                        "filename": gap_filename,
                        "start": covered_until,
                        "end": start,
                        "size": gap_size,
                    }
                )
                logger.info(
                    "Written: %s (0x%X - 0x%X) => %d bytes",
                    gap_path, covered_until, start, gap_size
                )
            covered_until = end

        tail_file: str | None = None
        if source_size > max_end:
            tail_size = source_size - max_end
            sboot.seek(max_end)
            tail_data = sboot.read(tail_size)
            if len(tail_data) != tail_size:
                raise RuntimeError(
                    f"Could not fully read tail area: expected {tail_size} bytes, "
                    f"got {len(tail_data)} bytes"
                )

            tail_path = os.path.join(out_dir, TAIL_FILENAME)
            with open(tail_path, "wb") as out:
                out.write(tail_data)

            tail_file = TAIL_FILENAME
            logger.info(
                "Written: %s (0x%X - 0x%X) => %d bytes",
                tail_path, max_end, source_size, tail_size
            )

    manifest = {
        "version": 2,
        "soc": soc,
        "source_size": source_size,
        "covered_end": max_end,
        "tail_file": tail_file,
        "parts": manifest_parts,
        "gaps": manifest_gaps,
    }
    manifest_path = os.path.join(out_dir, SPLIT_MANIFEST_NAME)
    with open(manifest_path, "w", encoding="utf-8") as manifest_file:
        json.dump(manifest, manifest_file, indent=2)
        manifest_file.write("\n")
    logger.info("Written: %s", manifest_path)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    parser = argparse.ArgumentParser(
        description="Extract split parts from sboot.bin using EXYNOS_DATA[soc]['bootloader_splits']."
    )
    parser.add_argument(
        "sboot",
        help="Path to sboot.bin",
    )
    parser.add_argument(
        "--soc",
        help="SoC string as in EXYNOS_DATA (for example 'Exynos9830\\0'). If not set, auto-detect from sboot.bin.",
        default="Exynos9830\0",
    )
    parser.add_argument(
        "-o",
        "--out",
        help="Output directory",
        default="sboot_splits",
    )

    args = parser.parse_args()

    if not os.path.isfile(args.sboot):
        logger.error("File not found: %s", args.sboot)
        sys.exit(1)

    try:
        soc = resolve_soc(args.sboot, args.soc)

        # Optional warning for legacy SoCs (does not affect split behavior)
        if soc in LEGACY_SOCS:
            logger.warning("Legacy SoC detected: %s", soc)

        logger.info("SoC: %s", soc)
        split_sboot(args.sboot, soc, args.out)
        logger.info("Done.")
    except Exception as e:
        logger.error("Error: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
