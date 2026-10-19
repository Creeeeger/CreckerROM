#!/usr/bin/env python3
# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later
"""Inspect RAW stream tables in the extracted Samsung reference firmwares.

This executes only metadata constructors inside a Unicorn ARM64 emulator; it
never loads the libraries on the host or modifies firmware files. Runtime
property/calibration-file access is stubbed. These are expected stream tables,
not evidence that the native multi-frame pipeline has captured on a device.
Optional inspection dependencies are separate from the ROM/APK builder.
"""

import argparse
import hashlib
import json
import re
import struct
import xml.etree.ElementTree as ET
from pathlib import Path

from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs
from elftools.elf.elffile import ELFFile
from unicorn import UC_ARCH_ARM64, UC_HOOK_CODE, UC_MODE_ARM, Uc
from unicorn.arm64_const import (
    UC_ARM64_REG_CPACR_EL1,
    UC_ARM64_REG_LR,
    UC_ARM64_REG_PC,
    UC_ARM64_REG_SP,
    UC_ARM64_REG_TPIDR_EL0,
    UC_ARM64_REG_X0,
    UC_ARM64_REG_X1,
    UC_ARM64_REG_X2,
)

BASE = 0x10000000
STACK = 0x20000000
TLS = 0x30000000
RET = 0x30002000
EXT = 0x40000000


def inspect(path, sensor, camera):
    with open(path, "rb") as stream:
        elf = ELFFile(stream)
        symbols = list(elf.get_section_by_name(".dynsym").iter_symbols())
        uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        hi = max(
            s["p_vaddr"] + s["p_memsz"]
            for s in elf.iter_segments()
            if s["p_type"] == "PT_LOAD"
        )
        uc.mem_map(0, (hi + 4095) & ~4095)
        for seg in elf.iter_segments():
            if seg["p_type"] == "PT_LOAD":
                uc.mem_write(seg["p_vaddr"], seg.data())
        uc.mem_map(BASE, 0x100000)
        uc.mem_map(STACK, 0x100000)
        uc.mem_map(TLS, 0x4000)
        uc.mem_map(EXT, 0x100000)
        ext = {}
        resolved = {}
        unknown = set()
        records = []
        for sec in elf.iter_sections():
            if sec["sh_type"] != "SHT_RELA":
                continue
            for r in sec.iter_relocations():
                t = r["r_info_type"]
                addr = r["r_offset"]
                add = r["r_addend"]
                if t == 1027:
                    value = add
                elif t in (1025, 1026, 257):
                    s = symbols[r["r_info_sym"]]
                    if s["st_value"]:
                        value = s["st_value"] + add
                    else:
                        if s.name not in resolved:
                            resolved[s.name] = EXT + len(resolved) * 16
                            ext[resolved[s.name]] = s.name
                        value = resolved[s.name] + add
                else:
                    continue
                uc.mem_write(addr, struct.pack("<Q", value))

        def hook(uc, addr, size, data):
            if addr not in ext:
                return
            name = ext[addr]
            a = uc.reg_read(UC_ARM64_REG_X0)
            b = uc.reg_read(UC_ARM64_REG_X1)
            c = uc.reg_read(UC_ARM64_REG_X2)
            result = 0
            if "memset" in name:
                uc.mem_write(a, bytes([b & 255]) * c)
                result = a
            elif "memcpy" in name or "memmove" in name:
                uc.mem_write(a, bytes(uc.mem_read(b, c)))
                result = a
            elif name == "__system_property_get" or name == "property_get":
                uc.mem_write(b, b"\0")
            elif name == "__android_log_print":
                pass
            elif name == "_ZN7android10VectorImpl3addEPKv":
                records.append(struct.unpack("<i", uc.mem_read(b, 4))[0])
                result = len(records) - 1
            elif name == "_ZN7android10VectorImpl11setCapacityEm":
                pass
            else:
                unknown.add(name)
            uc.reg_write(UC_ARM64_REG_X0, result)
            uc.reg_write(UC_ARM64_REG_PC, uc.reg_read(UC_ARM64_REG_LR))

        uc.hook_add(UC_HOOK_CODE, hook)
        uc.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20)
        uc.reg_write(UC_ARM64_REG_TPIDR_EL0, TLS)
        uc.reg_write(UC_ARM64_REG_SP, STACK + 0xFF000)
        uc.reg_write(UC_ARM64_REG_X0, BASE)
        uc.reg_write(UC_ARM64_REG_X1, camera)
        uc.reg_write(UC_ARM64_REG_X2, 0)
        uc.reg_write(UC_ARM64_REG_LR, RET)
        s = next(
            s
            for s in symbols
            if re.search(r"ExynosCameraSensor" + sensor + r"C[12]Eii", s.name)
        )
        factory = next(f for f in symbols if "createExynosCameraSensorInfo" in f.name)
        instructions = list(
            Cs(CS_ARCH_ARM64, CS_MODE_ARM).disasm(
                bytes(uc.mem_read(factory["st_value"], factory["st_size"])),
                factory["st_value"],
            )
        )
        sensor_ids = []
        for index, ins in enumerate(instructions):
            if ins.mnemonic == "bl" and int(ins.op_str[1:], 16) == s["st_value"]:
                values = [
                    int(i.op_str.split("#")[1], 0)
                    for i in instructions[max(0, index - 8) : index]
                    if i.mnemonic == "mov" and i.op_str.startswith("w2, #")
                ]
                if len(values) != 1:
                    raise RuntimeError("Sensor ID argument is ambiguous")
                sensor_ids.extend(values)
        if len(sensor_ids) != 1:
            raise RuntimeError("Constructor is not uniquely used by this firmware")
        uc.reg_write(UC_ARM64_REG_X2, sensor_ids[0])
        uc.emu_start(s["st_value"], RET, count=100000)
        if uc.reg_read(UC_ARM64_REG_PC) != RET:
            raise RuntimeError("Constructor did not return")
        streams = {}
        for key, needle, kind in [
            ("standard", "m_createScalerAvailableStreamConfigurationsOutput", 0),
            ("vendor", "m_createVendorControlAvailablePictureConfigurations", 0),
            ("vendor_crop", "m_createVendorControlAvailablePictureConfigurations", 1),
        ]:
            fn = next(s for s in symbols if needle in s.name)
            records.clear()
            uc.reg_write(UC_ARM64_REG_SP, STACK + 0xFF000)
            uc.reg_write(UC_ARM64_REG_X0, BASE)
            uc.reg_write(UC_ARM64_REG_X1, BASE + 0x20000)
            uc.reg_write(UC_ARM64_REG_X2, kind)
            uc.reg_write(UC_ARM64_REG_LR, RET)
            uc.emu_start(fn["st_value"], RET, count=500000)
            if uc.reg_read(UC_ARM64_REG_PC) != RET:
                raise RuntimeError("Metadata function did not return")
            if len(records) % 4:
                raise RuntimeError("Invalid metadata tuple length")
            streams[key] = [records[n : n + 4] for n in range(0, len(records), 4)]
        return {
            "sensor_id": sensor_ids[0],
            "streams": streams,
            "sensor": sensor,
            "camera": camera,
            "unknown_external": sorted(unknown),
        }


models = {
    "G780F": [("2LD", 0), ("3L6", 2), ("HI847", 52), ("IMX616", 1), ("IMX616", 3)],
    "G981B": [("2LD", 0), ("2LA", 2), ("GW2", 52), ("3J1", 1), ("3J1", 3)],
    "G986B": [("2LD", 0), ("2LA", 2), ("GW2", 52), ("3J1", 1), ("3J1", 3)],
    "G988B": [("HM1", 0), ("2L3", 2), ("IMX586", 52), ("GH1", 1), ("GH1", 3)],
    "N981B": [("2LD", 0), ("2LA", 2), ("GW2", 52), ("3J1", 1), ("3J1", 3)],
    "N986B": [("HM1", 0), ("2L3", 2), ("3M5", 52), ("3J1", 1), ("3J1", 3)],
}


def collect(firmware_root):
    root = Path(__file__).resolve().parent
    profiles = {
        json.loads(p.read_text())["models"][-1][3:]: json.loads(p.read_text())
        for p in (root / "profiles").glob("*.json")
    }
    result = {
        "author": "Creeeeger",
        "method": "Static emulation of Samsung sensor constructors and metadata stream generators; capture validation only on y2s",
        "devices": {},
    }
    for model, lenses in models.items():
        profile = profiles[model]
        fw = firmware_root / ("SM-" + model + "_AUT")
        lib = fw / "vendor/lib64/libexynoscamera3.so"
        xml = fw / "system/system/cameradata/camera-feature.xml"
        values = {e.get("name"): e.get("value") for e in ET.parse(xml).getroot()}
        for flag, value in {
            "BACK_WIDE_CAMERA_ID": "2",
            "BACK_TELE_CAMERA_ID": "52",
            "FRONT_DYNAMIC_FOV_CAMERA_ID": "3",
        }.items():
            if values.get(flag) != value:
                raise ValueError("Unexpected firmware camera ID: " + flag)
        cameras = []
        for sensor, camera in lenses:
            c = inspect(lib, sensor, camera)
            if set(c["unknown_external"]) - {
                "_ZdaPv",
                "_Znam",
                "__vsnprintf_chk",
                "__vsprintf_chk",
                "fopen",
            }:
                raise ValueError("Unrecognized runtime call in sensor constructor")
            cameras.append(
                {
                    "camera_id": camera,
                    "sensor": sensor,
                    "sensor_id": c["sensor_id"],
                    "standard_raw": [s for s in c["streams"]["standard"] if s[0] == 32],
                    "vendor_raw": [s for s in c["streams"]["vendor"] if s[0] == 32],
                    "runtime_calls_stubbed": c["unknown_external"],
                }
            )
        result["devices"][profile["device"]] = {
            "reference_model": "SM-" + model,
            "models": profile["models"],
            "firmware": (fw / ".extracted").read_text().strip(),
            "camera_feature_sha256": hashlib.sha256(xml.read_bytes()).hexdigest(),
            "hal_sha256": hashlib.sha256(lib.read_bytes()).hexdigest(),
            "stock_values": {
                k: values[k]
                for k in (
                    "BACK_WIDE_CAMERA_ID",
                    "BACK_TELE_CAMERA_ID",
                    "FRONT_DYNAMIC_FOV_CAMERA_ID",
                    "BACK_CAMERA_RESOLUTION_4BY3_LARGE",
                    "BACK_WIDE_CAMERA_RESOLUTION_4BY3_LARGE",
                    "FRONT_CAMERA_RESOLUTION_4BY3_LARGE",
                    "FRONT_CAMERA_SENSOR_CROP_RESOLUTION_4BY3_LARGE",
                )
            },
            "lenses": cameras,
        }
        print(profile["device"], "reference inspected:", model, flush=True)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--firmware-root",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "out/fw",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[2]
        / "out/expertraw/camera-references.json",
    )
    args = parser.parse_args()
    references = collect(args.firmware_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(references, indent=2) + "\n")
