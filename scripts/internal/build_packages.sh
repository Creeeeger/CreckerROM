#!/usr/bin/env bash
#
# Copyright (C) 2023 Salvo Giangreco
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
source "$SRC_DIR/scripts/utils/build_utils.sh" || exit 1
source "$SRC_DIR/scripts/utils/firmware_utils.sh" || exit 1

source "$SRC_DIR/scripts/internal/packaging/super_images.sh" || exit 1
source "$SRC_DIR/scripts/internal/packaging/image_inputs.sh" || exit 1
source "$SRC_DIR/scripts/internal/packaging/samsung_signing.sh" || exit 1
source "$SRC_DIR/scripts/internal/packaging/output_paths.sh" || exit 1
source "$SRC_DIR/scripts/internal/packaging/odin.sh" || exit 1
source "$SRC_DIR/scripts/internal/packaging/heimdall.sh" || exit 1
source "$SRC_DIR/scripts/internal/packaging/package_build.sh" || exit 1
