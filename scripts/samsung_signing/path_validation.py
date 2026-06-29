#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

from pathlib import Path


def require_file(path: Path) -> Path:
    if not path.is_file():
        raise FileNotFoundError(path)
    return path
