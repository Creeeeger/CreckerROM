#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

SKIPUNZIP=1

# Ship the release covered by the SSP patch, including over a store update.
ADD_TO_WORK_DIR "r12sxxx" "system" "system/app/BlockchainBasicKit/BlockchainBasicKit.apk" 0 0 644 "u:object_r:system_file:s0"

# SSP is present on Exynos990. Do not advertise securehw.status=Ready:
# Keystore also uses it to select KV2 storage, which drops the legacy PIN random.
