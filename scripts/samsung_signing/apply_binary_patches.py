#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class PatchRow:
    line_no: int
    offset: int
    old_bytes: bytes
    new_bytes: bytes
    function: str
    instruction: str


def parse_hex_blob(value: str, label: str, line_no: int) -> bytes:
    compact = "".join(value.split())
    try:
        return bytes.fromhex(compact)
    except ValueError as exc:
        raise ValueError(f"line {line_no}: invalid {label} hex: {value!r}") from exc


def load_patch_rows(
        path: Path,
        *,
        kvm: bool = False,
) -> tuple[list[PatchRow], int]:
    rows: list[PatchRow] = []
    disabled = 0

    with path.open("r", encoding="utf-8") as fh:
        reader = csv.reader(fh, delimiter="|")
        for line_no, fields in enumerate(reader, start=1):
            if not fields:
                continue
            if fields[0].strip().startswith("#"):
                continue
            if len(fields) < 4:
                raise ValueError(f"line {line_no}: expected at least 4 pipe-separated columns")

            profile = fields[0].strip().lower()
            enabled = (
                profile == "1"
                or (profile == "kvm" and kvm)
            )
            if not enabled:
                disabled += 1
                continue

            offset = int(fields[1].strip(), 0)
            old_bytes = parse_hex_blob(fields[2], "old", line_no)
            new_bytes = parse_hex_blob(fields[3], "new", line_no)
            if len(old_bytes) != len(new_bytes):
                raise ValueError(
                    f"line {line_no}: old/new byte lengths differ at 0x{offset:X} "
                    f"({len(old_bytes)} != {len(new_bytes)})"
                )
            if not old_bytes:
                raise ValueError(f"line {line_no}: empty patch at 0x{offset:X}")

            rows.append(
                PatchRow(
                    line_no=line_no,
                    offset=offset,
                    old_bytes=old_bytes,
                    new_bytes=new_bytes,
                    function=fields[4].strip() if len(fields) > 4 else "",
                    instruction=fields[5].strip() if len(fields) > 5 else "",
                )
            )

    return rows, disabled


def apply_patches(
        data: bytearray,
        rows: list[PatchRow],
        *,
        force: bool,
        dry_run: bool,
        target_label: str,
) -> tuple[int, int]:
    applied = 0
    already_applied = 0

    for row in rows:
        end = row.offset + len(row.old_bytes)
        if end > len(data):
            raise ValueError(
                f"line {row.line_no}: patch at 0x{row.offset:X} extends past "
                f"{target_label} size 0x{len(data):X}"
            )

        current = bytes(data[row.offset:end])
        if current == row.new_bytes:
            already_applied += 1
            print(f"[*] 0x{row.offset:08X}: already patched ({row.function})")
            continue
        if current != row.old_bytes and not force:
            raise ValueError(
                f"line {row.line_no}: old bytes mismatch at 0x{row.offset:X}; "
                f"expected {row.old_bytes.hex().upper()}, got {current.hex().upper()}"
            )

        print(
            f"[*] 0x{row.offset:08X}: {row.old_bytes.hex().upper()} -> "
            f"{row.new_bytes.hex().upper()} ({row.function})"
        )
        if not dry_run:
            data[row.offset:end] = row.new_bytes
        applied += 1

    return applied, already_applied


def patch_file(
        input_path: Path,
        patch_table: Path,
        *,
        output_path: Path | None = None,
        force: bool = False,
        dry_run: bool = False,
        target_label: str = "binary",
        kvm: bool = False,
) -> tuple[int, int, int]:
    if not input_path.is_file():
        raise FileNotFoundError(input_path)
    if not patch_table.is_file():
        raise FileNotFoundError(patch_table)

    rows, disabled = load_patch_rows(
        patch_table,
        kvm=kvm,
    )
    data = bytearray(input_path.read_bytes())
    applied, already = apply_patches(
        data,
        rows,
        force=force,
        dry_run=dry_run,
        target_label=target_label,
    )

    output = output_path if output_path is not None else input_path
    if not dry_run:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(data)

    print(
        f"[+] {target_label} patching finished: applied={applied} already_applied={already} "
        f"disabled={disabled} output={output}"
    )
    return applied, already, disabled


def main(*, target_label: str = "binary", description: str | None = None) -> None:
    parser = argparse.ArgumentParser(description=description or "Apply byte-exact patches from a TSV table")
    parser.add_argument("--input", "-i", type=Path, required=True, help="Input binary")
    parser.add_argument("--output", "-o", type=Path, help="Output path. Defaults to in-place patching.")
    parser.add_argument("--patch-table", "-p", type=Path, required=True, help="TSV patch table")
    parser.add_argument("--force", action="store_true", help="Patch even when old bytes do not match")
    parser.add_argument("--dry-run", action="store_true", help="Validate and print changes without writing")
    parser.add_argument(
        "--kvm",
        action="store_true",
        help="Enable rows whose profile column is 'kvm'",
    )
    args = parser.parse_args()

    patch_file(
        args.input,
        args.patch_table,
        output_path=args.output,
        force=args.force,
        dry_run=args.dry_run,
        target_label=target_label,
        kvm=args.kvm,
    )


if __name__ == "__main__":
    main()
