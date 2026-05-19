#!/usr/bin/env python3
#
# Parse Samsung TEE TA blobs and print their UUID/name metadata.
#
# Samsung TA files are commonly SEC2/SEC3 containers with an ELF payload at
# offset 8.  The SEC length usually covers the ELF image, with signature data
# trailing after it.  This script parses the ELF in memory and reads the
# TA_property section when present.

import argparse
import csv
import glob
import json
import re
import struct
import sys
from pathlib import Path


ELF_MAGIC = b"\x7fELF"
SEC_MAGICS = {b"SEC2", b"SEC3"}


class ParseError(Exception):
    pass


def unpack(fmt, data, offset):
    size = struct.calcsize(fmt)
    if offset < 0 or offset + size > len(data):
        raise ParseError("truncated data")
    return struct.unpack_from(fmt, data, offset)


def c_string(data):
    return data.split(b"\0", 1)[0].decode("ascii", "replace")


def printable_strings(data, min_len=3):
    out = []
    for match in re.finditer(rb"[\x20-\x7e]{%d,}" % min_len, data):
        out.append(match.group(0).decode("ascii", "replace").strip())
    return out


def format_uuid(raw):
    if not raw or len(raw) != 16:
        return ""
    hexed = raw.hex()
    return "-".join(
        [
            hexed[0:8],
            hexed[8:12],
            hexed[12:16],
            hexed[16:20],
            hexed[20:32],
        ]
    )


def filename_uuid(path):
    name = path.name
    if re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", name):
        return name.lower()
    return ""


def uuid_tail_name(uuid):
    if not uuid:
        return ""
    tail = uuid.split("-")[-1]
    try:
        raw = bytes.fromhex(tail)
    except ValueError:
        return ""
    text = "".join(chr(b) if 0x20 <= b <= 0x7E else "" for b in raw)
    return text.strip()


def find_elf(data):
    if data.startswith(ELF_MAGIC):
        return 0, "", ""

    if data[:4] in SEC_MAGICS and data[8:12] == ELF_MAGIC:
        sec_len = int.from_bytes(data[4:8], "big")
        return 8, data[:4].decode("ascii"), f"0x{sec_len:x}"

    # Be tolerant of unusual wrappers, but keep the scan shallow so we do not
    # accidentally identify unrelated embedded data as the TA image.
    offset = data.find(ELF_MAGIC, 0, min(len(data), 0x1000))
    if offset >= 0:
        return offset, "unknown", ""

    return None, "", ""


def parse_elf(data, elf_offset):
    ident = data[elf_offset : elf_offset + 16]
    if len(ident) < 16 or not ident.startswith(ELF_MAGIC):
        raise ParseError("missing ELF magic")

    elf_class = ident[4]
    endian_tag = ident[5]
    if endian_tag == 1:
        endian = "<"
        endian_name = "little"
    elif endian_tag == 2:
        endian = ">"
        endian_name = "big"
    else:
        raise ParseError("unknown ELF endian")

    if elf_class == 1:
        header = unpack(endian + "16sHHIIIIIHHHHHH", data, elf_offset)
        (
            _,
            e_type,
            e_machine,
            _e_version,
            e_entry,
            _e_phoff,
            e_shoff,
            _e_flags,
            _e_ehsize,
            _e_phentsize,
            _e_phnum,
            e_shentsize,
            e_shnum,
            e_shstrndx,
        ) = header
        sh_fmt = endian + "IIIIIIIIII"
        sh_size = struct.calcsize(sh_fmt)
    elif elf_class == 2:
        header = unpack(endian + "16sHHIQQQIHHHHHH", data, elf_offset)
        (
            _,
            e_type,
            e_machine,
            _e_version,
            e_entry,
            _e_phoff,
            e_shoff,
            _e_flags,
            _e_ehsize,
            _e_phentsize,
            _e_phnum,
            e_shentsize,
            e_shnum,
            e_shstrndx,
        ) = header
        sh_fmt = endian + "IIQQQQIIQQ"
        sh_size = struct.calcsize(sh_fmt)
    else:
        raise ParseError("unknown ELF class")

    if e_shoff == 0 or e_shnum == 0:
        return {
            "elf_class": f"ELF{elf_class * 32}",
            "endian": endian_name,
            "machine": f"0x{e_machine:x}",
            "type": f"0x{e_type:x}",
            "entry": f"0x{e_entry:x}",
            "sections": {},
        }

    if e_shentsize < sh_size:
        raise ParseError("unsupported section header size")

    sections = []
    for index in range(e_shnum):
        off = elf_offset + e_shoff + index * e_shentsize
        raw = unpack(sh_fmt, data, off)
        if elf_class == 1:
            sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size2, sh_link, sh_info, sh_addralign, sh_entsize = raw
        else:
            sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size2, sh_link, sh_info, sh_addralign, sh_entsize = raw
        sections.append(
            {
                "name_offset": sh_name,
                "type": sh_type,
                "flags": sh_flags,
                "addr": sh_addr,
                "offset": sh_offset,
                "size": sh_size2,
                "link": sh_link,
                "info": sh_info,
                "align": sh_addralign,
                "entsize": sh_entsize,
            }
        )

    if e_shstrndx >= len(sections):
        raise ParseError("bad section string table index")

    shstr = sections[e_shstrndx]
    shstr_data = data[elf_offset + shstr["offset"] : elf_offset + shstr["offset"] + shstr["size"]]
    named_sections = {}
    for section in sections:
        name = c_string(shstr_data[section["name_offset"] :]) if section["name_offset"] < len(shstr_data) else ""
        section["name"] = name
        named_sections[name] = section

    interp = ""
    if ".interp" in named_sections:
        section = named_sections[".interp"]
        raw = data[elf_offset + section["offset"] : elf_offset + section["offset"] + section["size"]]
        interp = c_string(raw)

    return {
        "elf_class": f"ELF{elf_class * 32}",
        "endian": endian_name,
        "machine": "ARM" if e_machine == 40 else "AArch64" if e_machine == 183 else f"0x{e_machine:x}",
        "type": "DYN" if e_type == 3 else f"0x{e_type:x}",
        "entry": f"0x{e_entry:x}",
        "interp": interp,
        "sections": named_sections,
    }


def parse_ta_property(data):
    if not data:
        return {}

    strings = printable_strings(data)
    version = ""
    desc = ""
    owner = ""

    for text in strings:
        lower = text.lower()
        if lower.startswith("ta version:"):
            version = text.split(":", 1)[1].strip()
        elif lower.startswith("ver."):
            version = text[4:].strip()
        elif lower.startswith("ta desc:"):
            desc = text.split(":", 1)[1].strip()
        elif lower.startswith("descr."):
            desc = text[6:].strip()
        elif text.startswith("samsung_"):
            owner = text

    if desc.lower() == "none":
        desc = ""
    if version.lower() == "none":
        version = ""

    return {
        "property_uuid": format_uuid(data[:16]) if len(data) >= 16 else "",
        "version": version,
        "desc": desc,
        "owner": owner,
        "property_strings": strings,
    }


def parse_file(path):
    data = path.read_bytes()
    elf_offset, container, sec_len = find_elf(data)
    file_uuid = filename_uuid(path)

    result = {
        "path": str(path),
        "file": path.name,
        "file_uuid": file_uuid,
        "container": container,
        "sec_length": sec_len,
        "elf_offset": "" if elf_offset is None else f"0x{elf_offset:x}",
        "elf_class": "",
        "machine": "",
        "entry": "",
        "interp": "",
        "uuid": file_uuid,
        "name": uuid_tail_name(file_uuid),
        "desc": "",
        "version": "",
        "owner": "",
        "status": "no ELF payload",
    }

    if elf_offset is None:
        return result

    elf = parse_elf(data, elf_offset)
    result.update(
        {
            "elf_class": elf.get("elf_class", ""),
            "machine": elf.get("machine", ""),
            "entry": elf.get("entry", ""),
            "interp": elf.get("interp", ""),
            "status": "ok",
        }
    )

    section = elf["sections"].get("TA_property")
    if not section:
        result["status"] = "missing TA_property"
        return result

    prop_data = data[elf_offset + section["offset"] : elf_offset + section["offset"] + section["size"]]
    prop = parse_ta_property(prop_data)
    prop_uuid = prop.get("property_uuid", "")

    result.update(
        {
            "uuid": prop_uuid or file_uuid,
            "desc": prop.get("desc", ""),
            "version": prop.get("version", ""),
            "owner": prop.get("owner", ""),
        }
    )

    result["name"] = result["desc"] or uuid_tail_name(result["uuid"]) or uuid_tail_name(file_uuid)
    return result


def candidate_paths(args):
    if args.paths:
        paths = [Path(p) for p in args.paths]
    else:
        paths = []
        for pattern in ("out/target/*/work_dir/vendor/tee", "out/fw/*/vendor/tee"):
            paths.extend(Path(p) for p in sorted(glob.glob(pattern)))
        if not paths:
            paths = [Path(".")]

    files = []
    for path in paths:
        if path.is_dir():
            for child in sorted(path.iterdir()):
                if child.is_file():
                    if not args.include_elf and child.suffix == ".elf":
                        continue
                    files.append(child)
        elif path.is_file():
            files.append(path)

    return files


def write_table(rows):
    columns = ["uuid", "name", "version", "owner", "elf_class", "machine", "container", "status", "path"]
    widths = {}
    for column in columns:
        widths[column] = max(len(column), *(len(str(row.get(column, ""))) for row in rows)) if rows else len(column)

    print("  ".join(column.ljust(widths[column]) for column in columns))
    print("  ".join("-" * widths[column] for column in columns))
    for row in rows:
        print("  ".join(str(row.get(column, "")).ljust(widths[column]) for column in columns))


def main():
    parser = argparse.ArgumentParser(description="Parse Samsung TEE TA blobs and print UUID/name metadata.")
    parser.add_argument("paths", nargs="*", help="TA files or directories to scan. Defaults to out/*/vendor/tee.")
    parser.add_argument("--include-elf", action="store_true", help="Include already-extracted .elf files when scanning a directory.")
    parser.add_argument("--format", choices=("table", "csv", "json"), default="table", help="Output format.")
    args = parser.parse_args()

    rows = []
    failed = False
    for path in candidate_paths(args):
        try:
            rows.append(parse_file(path))
        except OSError as exc:
            failed = True
            rows.append({"path": str(path), "file": path.name, "status": f"I/O error: {exc}"})
        except ParseError as exc:
            failed = True
            rows.append({"path": str(path), "file": path.name, "status": f"parse error: {exc}"})

    if args.format == "json":
        print(json.dumps(rows, indent=2, sort_keys=True))
    elif args.format == "csv":
        columns = ["uuid", "name", "desc", "version", "owner", "elf_class", "machine", "container", "sec_length", "elf_offset", "entry", "interp", "status", "path"]
        writer = csv.DictWriter(sys.stdout, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    else:
        write_table(rows)

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
