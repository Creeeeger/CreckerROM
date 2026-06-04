#!/usr/bin/env bash
#
# Copyright (C) 2026
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

# [
source "$SRC_DIR/scripts/utils/firmware_utils.sh" || exit 1

# This wrapper only wires function modules together; avb/pipeline.sh owns the
# execution order and keeps the cross-module state in globals.
source "$SRC_DIR/scripts/internal/avb/configuration.sh" || exit 1
source "$SRC_DIR/scripts/internal/avb/keys.sh" || exit 1
source "$SRC_DIR/scripts/internal/avb/image_metadata.sh" || exit 1
source "$SRC_DIR/scripts/internal/avb/image_discovery.sh" || exit 1
source "$SRC_DIR/scripts/internal/avb/signing.sh" || exit 1
source "$SRC_DIR/scripts/internal/avb/packaging.sh" || exit 1
source "$SRC_DIR/scripts/internal/avb/pipeline.sh" || exit 1
