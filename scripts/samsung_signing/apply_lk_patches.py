#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

from apply_binary_patches import main

if __name__ == "__main__":
    main(
        target_label="LK",
        description="Apply byte-exact LK patches from a default-model TSV table",
    )
