#!/usr/bin/env python3
import argparse
import json
import logging
import os
import sys

from soc_data import EXYNOS_DATA, LEGACY_SOCS

logger = logging.getLogger("sboot_merger")
DEFAULT_OUTPUT = "sboot.bin"
ZERO_PADDING_CHUNK_SIZE = 1024 * 1024
SPLIT_MANIFEST_NAME = "split_manifest.json"


def normalize_soc(soc_arg: str) -> str:
    soc = soc_arg
    if not soc.endswith("\0"):
        soc += "\0"
    return soc


def parse_positive_size(value: str) -> int:
    try:
        size = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"Invalid size value: {value!r}") from exc

    if size <= 0:
        raise argparse.ArgumentTypeError("Size must be a positive integer.")
    return size


def load_split_manifest(parts_dir: str) -> dict | None:
    manifest_path = os.path.join(parts_dir, SPLIT_MANIFEST_NAME)
    if not os.path.isfile(manifest_path):
        return None

    with open(manifest_path, "r", encoding="utf-8") as manifest_file:
        manifest = json.load(manifest_file)

    if not isinstance(manifest, dict):
        raise RuntimeError(f"Invalid manifest format in {manifest_path}: expected JSON object.")

    logger.info("Using manifest: %s", manifest_path)
    return manifest


def resolve_part_path(parts_dir: str, part_name: str) -> str:
    candidates = [part_name]
    if not os.path.splitext(part_name)[1]:
        candidates.append(f"{part_name}.bin")

    for candidate in candidates:
        path = os.path.join(parts_dir, candidate)
        if os.path.isfile(path):
            return path

    candidate_list = ", ".join(candidates)
    raise FileNotFoundError(
        f"Part file for {part_name!r} not found. Expected one of: {candidate_list}"
    )


def load_splits_for_soc(soc: str) -> list[tuple[str, int, int]]:
    if soc not in EXYNOS_DATA:
        available = ", ".join(sorted(repr(s) for s in EXYNOS_DATA.keys()))
        raise RuntimeError(f"SoC not supported in EXYNOS_DATA: {soc!r}. Available: {available}")

    splits = EXYNOS_DATA[soc].get("bootloader_splits")
    if not splits:
        raise RuntimeError(f"No bootloader_splits found for SoC {soc!r}.")

    ranges: list[tuple[str, int, int]] = []
    for part_name, params in splits.items():
        start = params["start"]
        end = params["end"]
        if end <= start:
            raise RuntimeError(f"Invalid range for {part_name}: start={start}, end={end}")
        ranges.append((part_name, start, end))

    ranges.sort(key=lambda item: item[1])

    for idx in range(len(ranges) - 1):
        cur_name, cur_start, cur_end = ranges[idx]
        next_name, next_start, _ = ranges[idx + 1]
        if cur_end > next_start:
            raise RuntimeError(
                f"Overlapping ranges: {cur_name} (0x{cur_start:X}-0x{cur_end:X}) "
                f"and {next_name} (from 0x{next_start:X})"
            )

    return ranges


def write_zero_padding(file_obj, size: int) -> None:
    remaining = size
    while remaining > 0:
        chunk_size = min(remaining, ZERO_PADDING_CHUNK_SIZE)
        file_obj.write(b"\x00" * chunk_size)
        remaining -= chunk_size


def merge_parts(parts_dir: str, soc: str, output_path: str, final_size: int | None) -> None:
    ranges = load_splits_for_soc(soc)
    max_end = max(end for _, _, end in ranges)
    write_pos = 0
    total_padded = 0
    total_inserted = 0
    manifest = load_split_manifest(parts_dir)
    manifest_source_size: int | None = None
    manifest_tail_file: str | None = None

    if manifest is not None:
        manifest_soc = manifest.get("soc")
        if isinstance(manifest_soc, str) and manifest_soc != soc:
            logger.warning(
                "Manifest SoC (%r) differs from selected SoC (%r).",
                manifest_soc, soc
            )

        source_size_raw = manifest.get("source_size")
        if isinstance(source_size_raw, int) and source_size_raw > 0:
            manifest_source_size = source_size_raw
        elif source_size_raw is not None:
            logger.warning("Ignoring invalid source_size in manifest: %r", source_size_raw)

        tail_file_raw = manifest.get("tail_file")
        if isinstance(tail_file_raw, str) and tail_file_raw:
            manifest_tail_file = tail_file_raw

    with open(output_path, "wb") as out:
        for part_name, start, end in ranges:
            if start < write_pos:
                raise RuntimeError(
                    f"Invalid layout while merging: {part_name} starts at 0x{start:X}, "
                    f"but current write position is already 0x{write_pos:X}"
                )

            if start > write_pos:
                pad_size = start - write_pos
                write_zero_padding(out, pad_size)
                logger.info(
                    "Padded: 0x%X - 0x%X (%d bytes)",
                    write_pos, start, pad_size
                )
                write_pos = start
                total_padded += pad_size

            expected_size = end - start
            part_path = resolve_part_path(parts_dir, part_name)

            with open(part_path, "rb") as f:
                data = f.read()

            if len(data) != expected_size:
                raise RuntimeError(
                    f"Invalid size for {part_name}: expected {expected_size} bytes, got {len(data)} bytes "
                    f"({part_path})"
                )

            out.write(data)
            write_pos = end
            total_inserted += expected_size
            logger.info(
                "Inserted: %s => 0x%X - 0x%X (%d bytes)",
                part_path, start, end, expected_size
            )

        if write_pos < max_end:
            trailing_pad = max_end - write_pos
            write_zero_padding(out, trailing_pad)
            logger.info(
                "Padded: 0x%X - 0x%X (%d bytes)",
                write_pos, max_end, trailing_pad
            )
            write_pos = max_end
            total_padded += trailing_pad

        if manifest_tail_file:
            tail_path = os.path.join(parts_dir, manifest_tail_file)
            if not os.path.isfile(tail_path):
                raise RuntimeError(f"Manifest tail_file not found: {tail_path}")

            with open(tail_path, "rb") as tail_file:
                tail_data = tail_file.read()

            out.write(tail_data)
            logger.info(
                "Appended tail: %s => 0x%X - 0x%X (%d bytes)",
                tail_path, write_pos, write_pos + len(tail_data), len(tail_data)
            )
            write_pos += len(tail_data)
            total_inserted += len(tail_data)

        target_size = final_size if final_size is not None else manifest_source_size
        if target_size is not None:
            if target_size < write_pos:
                raise RuntimeError(
                    f"Final size too small: requested {target_size} bytes, "
                    f"but merged data already has {write_pos} bytes."
                )

            if target_size > write_pos:
                final_pad = target_size - write_pos
                write_zero_padding(out, final_pad)
                logger.info(
                    "Padded: 0x%X - 0x%X (%d bytes)",
                    write_pos, target_size, final_pad
                )
                write_pos = target_size
                total_padded += final_pad

    logger.info("Summary: inserted=%d bytes, padded=%d bytes", total_inserted, total_padded)
    logger.info("Written: %s (%d bytes)", output_path, write_pos)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    parser = argparse.ArgumentParser(
        description=(
            "Builds sboot.bin from split parts using EXYNOS_DATA[soc]['bootloader_splits']."
        )
    )
    parser.add_argument(
        "parts_dir",
        help="Directory with split files (for example output of split.py)",
    )
    parser.add_argument(
        "soc",
        help="SoC string as in EXYNOS_DATA (for example 'Exynos9830\\0').",
    )
    parser.add_argument(
        "--final-size",
        type=parse_positive_size,
        help=(
            "Optional final size in bytes (decimal or hex, for example 4194304 or 0x400000). "
            "If larger than merged data, zero padding is appended."
        ),
    )

    args = parser.parse_args()

    if not os.path.isdir(args.parts_dir):
        logger.error("Directory not found: %s", args.parts_dir)
        sys.exit(1)

    soc = normalize_soc(args.soc)
    if soc in LEGACY_SOCS:
        logger.warning("Legacy SoC detected: %s", soc)

    logger.info("SoC: %s", soc)
    if os.path.exists(DEFAULT_OUTPUT):
        logger.warning("%s already exists and will be overwritten.", DEFAULT_OUTPUT)

    try:
        merge_parts(
            parts_dir=args.parts_dir,
            soc=soc,
            output_path=DEFAULT_OUTPUT,
            final_size=args.final_size,
        )
        logger.info("Done.")
    except Exception as e:
        logger.error("Error: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
