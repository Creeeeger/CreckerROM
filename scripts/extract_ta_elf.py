#!/usr/bin/env python3
import sys
from pathlib import Path

ELF_MAGIC = b"\x7fELF"
SEC_MAGICS = {b"SEC2", b"SEC3"}

def extract_elf(path: Path) -> Path:
    data = path.read_bytes()

    if data.startswith(ELF_MAGIC):
        out = path.with_suffix(path.suffix + ".elf")
        out.write_bytes(data)
        return out

    if data[:4] not in SEC_MAGICS:
        raise ValueError(f"{path}: not SEC2/SEC3")

    sec_len = int.from_bytes(data[4:8], "big")

    if data[8:12] != ELF_MAGIC:
        raise ValueError(f"{path}: no ELF at offset 8")

    end = 8 + sec_len

    if end > len(data):
        raise ValueError(
            f"{path}: SEC length exceeds file size "
            f"(sec_len=0x{sec_len:x}, file_size=0x{len(data):x})"
        )

    elf = data[8:end]

    if not elf.startswith(ELF_MAGIC):
        raise ValueError(f"{path}: extracted payload is not ELF")

    out = path.with_suffix(path.suffix + ".elf")
    out.write_bytes(elf)
    return out

def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} TA_FILE ...", file=sys.stderr)
        return 2

    failed = False
    for arg in sys.argv[1:]:
        try:
            out = extract_elf(Path(arg))
            print(f"{arg} -> {out}")
        except Exception as exc:
            failed = True
            print(f"{arg}: {exc}", file=sys.stderr)

    return 1 if failed else 0

if __name__ == "__main__":
    raise SystemExit(main())