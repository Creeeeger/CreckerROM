#!/usr/bin/env python3
"""Power Policy Manager: configure logging and swap after firmware overlays."""

import argparse
from pathlib import Path


def properties(debug: bool) -> dict[str, str]:
    return {
        "persist.log.level": "0xFFFFFFFF" if debug else "0x0",
        "persist.log.semlevel": "0xFFFFFFFF" if debug else "0x0",
        "persist.log.tag": "V" if debug else "W",
        "log.tag": "V" if debug else "W",
        "ro.debug_level": "0x494d" if debug else "0x4f4c",
        "persist.sys.zram.ram_expand_size": "0",
        "ro.sys.kernelmemory.nandswap.quickswap": "false",
        "ro.sys.kernelmemory.nandswap.swap_after_boot": "false",
        "ro.sys.kernelmemory.nandswap.writeback_on_bg": "false",
        "ro.sys.kernelmemory.nandswap.prefetch_action": "false",
    }


def log_priority(key: str, value: str, debug: bool) -> str:
    # Per-tag settings take precedence over the global liblog threshold.
    if not debug and key.startswith(("log.tag.", "persist.log.tag.")):
        if value.upper() in {"V", "VERBOSE", "D", "DEBUG", "I", "INFO"}:
            return "W"
    return value


def configure_props(text: str, debug: bool, defaults: bool = False) -> str:
    policy = properties(debug)
    lines = []
    seen = set()
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and not key.startswith("#"):
            key = key.strip()
            if key in policy:
                value = policy[key]
                seen.add(key)
            value = log_priority(key, value.strip(), debug)
            line = f"{key}={value}"
        lines.append(line)
    if defaults:
        lines.extend(f"{key}={value}" for key, value in policy.items() if key not in seen)
    return "\n".join(lines) + "\n"


def configure_init(text: str, debug: bool) -> str:
    policy = properties(debug)
    lines = []
    skip_service = False
    for line in text.splitlines():
        stripped = line.strip()
        # Init sections begin at column zero; blank lines/comments do not end them.
        if line and not line[0].isspace() and not stripped.startswith("#"):
            skip_service = False
            if stripped.startswith("service "):
                words = stripped.split()
                binary = Path(words[2]).name
                skip_service = binary == "sswap" or (
                    not debug and binary in {"main_abox", "abox_log"}
                )
        if skip_service:
            continue
        if not stripped or stripped.startswith("#"):
            lines.append(line)
            continue
        words = stripped.split()
        # No automatic swap activation, including a stale RAM Plus setting.
        if words[0] in {"swapon_all", "swapon"}:
            continue
        if words[0] in {"start", "restart", "enable", "stop"} and len(words) > 1:
            if words[1] == "swapon" or (not debug and words[1] in {"abox", "abox_log"}):
                continue
        # Do not leave writes/chowns targeting a device that the kernel omits.
        if any("/zram" in word or word == "/proc/sys/vm/swappiness" for word in words[1:]):
            continue
        if words[0] == "setprop" and len(words) >= 3:
            key = words[1]
            value = policy.get(key, log_priority(key, words[2], debug))
            if key in policy or value != words[2]:
                line = f"    setprop {key} {value}"
        lines.append(line)
    # Remove actions left empty after stripping their swap commands.
    result = []
    section = []
    for line in lines + ["on __end_of_file__"]:
        if line and not line[0].isspace() and not line.startswith("#"):
            if section:
                if not section[0].startswith("on ") or any(
                    item.strip() and not item.lstrip().startswith("#") for item in section[1:]
                ):
                    result.extend(section)
            section = []
        section.append(line)
    return "\n".join(result).rstrip() + "\n"


def configure_fstab(text: str) -> str:
    lines = []
    for line in text.splitlines():
        words = line.split()
        if words and not words[0].startswith("#"):
            if len(words) >= 3 and words[2] == "swap":
                continue
        lines.append(line)
    return "\n".join(lines) + "\n"


def configure(work_dir: Path, debug: bool) -> None:
    system_props = work_dir / "system/system/build.prop"
    if not system_props.is_file():
        raise FileNotFoundError(system_props)
    for partition in ("system", "system_ext", "vendor", "odm", "product", "vendor_dlkm", "system_dlkm"):
        root = work_dir / partition
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            if path.name in {"build.prop", "default.prop", "prop.default"}:
                old = path.read_text()
                new = configure_props(old, debug, defaults=path == system_props)
            elif path.suffix == ".rc":
                old = path.read_text()
                new = configure_init(old, debug)
            elif path.name.startswith("fstab.") or path.name == "fstab":
                old = path.read_text()
                new = configure_fstab(old)
            else:
                continue
            if old != new:
                path.write_text(new)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("work_dir", type=Path)
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()
    configure(args.work_dir, args.debug)


if __name__ == "__main__":
    main()
