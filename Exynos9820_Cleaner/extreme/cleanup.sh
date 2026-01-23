#!/sbin/sh
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Written by @ExtremeXT and @david42069

function unmount() {
	umount -f /system_root
	umount -f /vendor
	umount -f /product
	umount -f /odm
	umount -f /prism
	umount -f /optics
	umount -f /cache
	umount -f /omr
	umount -f /data
	umount -f /sdcard
	umount -f /metadata
}

function format() {
    mke2fs -t ext4 -F /dev/block/by-name/system
    mke2fs -t ext4 -F /dev/block/by-name/vendor
    mke2fs -t ext4 -F /dev/block/by-name/product
    mke2fs -t ext4 -F /dev/block/by-name/odm
    mke2fs -t ext4 -F /dev/block/by-name/prism
    mke2fs -t ext4 -F /dev/block/by-name/optics
    mke2fs -t ext4 -F /dev/block/by-name/cache
    mke2fs -t ext4 -F /dev/block/by-name/omr
    mke2fs -t ext4 -F /dev/block/by-name/cp_debug
    mke2fs -t ext4 -F /dev/block/by-name/cp2_debug
    mke2fs -t ext4 -F /dev/block/by-name/spu
    mke2fs -t f2fs -F /dev/block/by-name/userdata
    mke2fs -t ext4 -F /dev/block/by-name/metadata
    /system/bin/make_f2fs -g android -O project_quota,extra_attr -O casefold -C utf8 /dev/block/by-name/userdata && sload_f2fs -t /data /dev/block/by-name/userdata
}

unmount
format
