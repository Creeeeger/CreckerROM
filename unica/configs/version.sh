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

VERSION_MAJOR=2
VERSION_MINOR=7
VERSION_PATCH=0

ROM_VERSION="${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"

# Release signing metadata; updating this does not apply Android security fixes.
# Keep aligned with PIF_SECURITY_PATCH in the bundled Play Integrity profile.
ROM_SECURITY_PATCH_LEVEL="2026-10-05"

ROM_CODENAME="S24FE"
ROM_DISPLAY_NAME="CROM-${ROM_CODENAME}-Official-${ROM_VERSION}"
