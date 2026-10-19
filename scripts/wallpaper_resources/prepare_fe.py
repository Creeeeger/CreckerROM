#!/usr/bin/env python3
# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare S20 FE wallpaper resources using a One UI 7 wallpaper APK as a base."""

import argparse
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


def prepare(stock: Path, modern: Path, output: Path, apktool: str) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="s20-fe-wallpapers-") as directory:
        workspace = Path(directory)
        original = workspace / "stock"
        target = workspace / "modern"
        for apk, decoded in ((stock, original), (modern, target)):
            subprocess.run([apktool, "d", "-s", "-o", str(decoded), str(apk)], check=True)

        # Keep the modern colour, graphical, frame and feature resources, but
        # replace the S20 artwork and catalog with the FE firmware originals.
        removed = set()
        for folder in target.joinpath("res").iterdir():
            if folder.is_dir():
                for asset in folder.iterdir():
                    if asset.stem.startswith(("wallpaper_", "dex_wallpaper_", "video_")):
                        removed.add(asset.stem)
                        asset.unlink()
        artwork = [f"wallpaper_{index:03d}.webp" for index in range(1, 9)]
        for index in range(1, 5):
            artwork.extend((f"dex_wallpaper_{index}.webp", f"dex_wallpaper_{index}_thumb.webp"))
        artwork.append("default_thumb.webp")
        for name in artwork:
            shutil.copy2(original / "res/drawable-nodpi" / name, target / "res/drawable-nodpi" / name)
            removed.discard(Path(name).stem)
        shutil.copy2(original / "res/raw/resources_info.json", target / "res/raw/resources_info.json")
        target.joinpath("res/raw/build_info.txt").write_text(
            "Target Device: r8s (SM-G780F)\nOneUI Version: 70000\n"
            "Artwork and colour defaults: stock SM-G780F wallpaper-res.apk\n",
            encoding="utf-8",
        )

        # Drop public IDs for the S20-only ninth image and video wallpapers.
        public_path = target / "res/values/public.xml"
        public = ET.parse(public_path)
        for entry in list(public.getroot()):
            if entry.get("name") in removed:
                public.getroot().remove(entry)
        public.write(public_path, encoding="utf-8", xml_declaration=True)
        subprocess.run([apktool, "b", str(target), "-o", str(output.resolve())], check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stock", type=Path, help="Stock SM-G780F wallpaper-res.apk")
    parser.add_argument("modern", type=Path, help="Supplied hubble-x1-y2 One UI 7 APK")
    parser.add_argument("output", type=Path, help="Unsigned FE wallpaper-res.apk")
    parser.add_argument("--apktool", default="apktool", help="Path to apktool")
    args = parser.parse_args()
    prepare(args.stock, args.modern, args.output, args.apktool)


if __name__ == "__main__":
    main()
