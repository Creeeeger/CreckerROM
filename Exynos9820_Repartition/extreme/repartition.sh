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
# Written by @Astrako
# Adapted to 9810 by @xxmustafacooTR and @JeyKul
# Adapted to 9820 by @ExtremeXT and @david42069

# New partitions sizes in MiB. Do NOT play with them unless you're a developer and know what you're doing.
systemsize=7000
vendorsize=1500
productsize=1500
odmsize=4
prismsize=600
opticssize=30
cachesize=6000
omrsize=50
cpdbgsize=5
spusize=50
metadatasize=200

# Other Variables
SGDISK=sgdisk
PARTED=/tmp/parted
JQ=/tmp/jq
DISK=/dev/block/sda

system=`$SGDISK --print $DISK | grep system | awk '{printf $1}'`
vendor=`$SGDISK --print $DISK | grep vendor | awk '{printf $1}'`
product=`$SGDISK --print $DISK | grep product | awk '{printf $1}'`
odm=`$SGDISK --print $DISK | grep odm | awk '{printf $1}'`
prism=`$SGDISK --print $DISK | grep prism | awk '{printf $1}'`
optics=`$SGDISK --print $DISK | grep optics | awk '{printf $1}'`
cache=`$SGDISK --print $DISK | grep cache | awk '{printf $1}'`
omr=`$SGDISK --print $DISK | grep omr | awk '{printf $1}'`
cp_debug=`$SGDISK --print $DISK | grep cp_debug | awk '{printf $1}'`
cp2_debug=`$SGDISK --print $DISK | grep cp2_debug | awk '{printf $1}'`
spu=`$SGDISK --print $DISK | grep spu | awk '{printf $1}'`
metadata=`$SGDISK --print $DISK | grep metadata | awk '{printf $1}'`
userdata=`$SGDISK --print $DISK | grep userdata | awk '{printf $1}'`

DISKCODE=`$SGDISK --print $DISK | grep system | awk '{printf $6}'`

function delete() {
	# Delete partitions
	$SGDISK --delete=$1 $DISK
}

function unmount() {
	umount -f /system_root
	umount -f /vendor
	umount -f /product
	umount -f /odm
	umount -f /prism
	umount -f /optics
	umount -f /cache
	umount -f /omr
	umount -f /metadata
	umount -f /data
	umount -f /sdcard
}

function calculate() {
	# Get vendor partition number and delete it, if exists
	if [ ! -z $vendor ]; then
		delete $vendor
	fi

	# Get product partition number and delete it, if exists
	if [ ! -z $product ]; then
		delete $product
	fi

	# Get odm partition number and delete it, if exists
	if [ ! -z $odm ]; then
		delete $odm
	fi

	# Get prism partition number and delete it, if exists
	if [ ! -z $prism ]; then
		delete $prism
	fi

	# Get optics partition number and delete it, if exists
	if [ ! -z $optics ]; then
		delete $optics
	fi

	# Get cache partition number and delete it, if exists
	if [ ! -z $cache ]; then
		delete $cache
	fi
	
	# Get omr partition number and delete it, if exists
	if [ ! -z $omr ]; then
		delete $omr
	fi
	
	# Get cp_debug partition number and delete it, if exists
	if [ ! -z $cp_debug ]; then
		delete $cp_debug
	fi

	# Get cp2_debug partition number and delete it, if exists
	if [ ! -z $cp2_debug ]; then
		delete $cp2_debug
	fi

	# Get spu partition number and delete it, if exiss
	if [ ! -z $spu ]; then
		delete $spu
	fi

	# Get metadata partition number and delete it, if exists
	if [ ! -z $metadata ]; then
		delete $metadata
	fi

	# Get userdata partition number and delete it
    if [ ! -z $userdata ]; then
		delete $userdata
	fi
}

function expand() {
	output=$($PARTED /dev/block/sda -s -j unit MiB print 2>/dev/null)

	system_orig_end=$(echo "$output" | $JQ -r '.disk.partitions[] | select(.name == "system") | .end' | sed 's/MiB$//')
	system_orig_size=$(echo "$output" | $JQ -r '.disk.partitions[] | select(.name == "system") | .size' | sed 's/MiB$//')
	system_num=$(echo "$output" | $JQ -r '.disk.partitions[] | select(.name == "system") | .number')
	system_size_delta=$(echo "$systemsize - $system_orig_size" | bc)
	system_new_end=$(echo "$system_orig_end + $system_size_delta" | bc)

	echo -e "Yes" | $PARTED /dev/block/sda resizepart $system_num "${system_new_end}MiB"
}

function repart() {	
	# vendor repartition
	$SGDISK --new=0:0:+${vendorsize}Mib --typecode=0:$DISKCODE --change-name=0:vendor $DISK

	# product repartition
	$SGDISK --new=0:0:+${productsize}Mib --typecode=0:$DISKCODE --change-name=0:product $DISK

	# odm repartition
	$SGDISK --new=0:0:+${odmsize}Mib --typecode=0:$DISKCODE --change-name=0:odm $DISK

	# prism repartition
	$SGDISK --new=0:0:+${prismsize}Mib --typecode=0:$DISKCODE --change-name=0:prism $DISK

	# optics repartition
	$SGDISK --new=0:0:+${opticssize}Mib --typecode=0:$DISKCODE --change-name=0:optics $DISK
	
	# cache repartition
	$SGDISK --new=0:0:+${cachesize}Mib --typecode=0:$DISKCODE --change-name=0:cache $DISK

	# omr repartition
	$SGDISK --new=0:0:+${omrsize}Mib --typecode=0:$DISKCODE --change-name=0:omr $DISK
		
	# cp_debug repartition
    $SGDISK --new=0:0:+${cpdbgsize}Mib --typecode=0:$DISKCODE --change-name=0:cp_debug $DISK

	# cp2_debug repartition if it exists
    if [ ! -z $cp2_debug ]; then
       	$SGDISK --new=0:0:+${cpdbgsize}Mib --typecode=0:$DISKCODE --change-name=0:cp2_debug $DISK
	fi

	# spu repartition if it exists
    if [ ! -z $spu ]; then
        $SGDISK --new=0:0:+${spusize}Mib --typecode=0:$DISKCODE --change-name=0:spu $DISK
	fi

	# metadata repartition
	$SGDISK --new=0:0:+${metadatasize}Mib --typecode=0:$DISKCODE --change-name=0:metadata $DISK

	# userdata repartition
	$SGDISK --new=0:0:0 --typecode=0:$DISKCODE --change-name=0:userdata $DISK
}

# main
unmount
calculate
expand
repart
