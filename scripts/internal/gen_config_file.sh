#!/usr/bin/env bash
#
# Copyright (C) 2025 Salvo Giangreco
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# [
source "$SRC_DIR/scripts/utils/common_utils.sh" || exit 1
source "$SRC_DIR/scripts/samsung_signing/bl1_model_metadata.sh" || exit 1

trap '[ $? -ne 0 ] && rm -f "$OUT_DIR/config.sh"' EXIT

source "$SRC_DIR/scripts/internal/config/defaults.sh" || exit 1

if [ $# -ne 1 ]; then
    echo "Usage: gen_config_file <target>" >&2
    exit 1
elif [ ! -f "$SRC_DIR/target/$1/config.sh" ]; then
    LOGE "File not found: target/$1/config.sh"
    exit 1
else
    SANITIZE_CONFIG_ENV
    source "$SRC_DIR/unica/configs/version.sh" || exit 1
    source "$SRC_DIR/target/$1/config.sh" || exit 1
fi

source "$SRC_DIR/scripts/internal/config/generator.sh" || exit 1
exit 0
