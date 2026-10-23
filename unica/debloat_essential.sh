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
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# Essential debloat list (always applied, including when ROM_DEBLOAT_LEVEL="none")
# - Keep this list very small and only include removals you always want.
# - Add entries inside the specific partition containing that file (<PARTITION>_DEBLOAT+="")
# - DO NOT add the partition name at the start of any entry (eg. "/system/dpolicy_system")
# - DO NOT add a slash at the start of any entry (eg. "/dpolicy_system")

# Recovery restoration script
VENDOR_DEBLOAT+="
recovery-from-boot.p
bin/install-recovery.sh
etc/init/vendor_flash_recovery.rc
"

# Samsung SIM Unlock
SYSTEM_DEBLOAT+="
"

# Facebook/Meta App Manager, App Installer, Services and preloaded app
SYSTEM_DEBLOAT+="
system/app/FBAppManager_NS
system/etc/default-permissions/default-permissions-meta.xml
system/etc/permissions/privapp-permissions-meta.xml
system/etc/sysconfig/meta-hiddenapi-package-allowlist.xml
system/preload/Facebook_stub_preload
system/priv-app/FBInstaller_NS
system/priv-app/FBServices
"

# Microsoft OneDrive
SYSTEM_DEBLOAT+="
system/etc/permissions/privapp-permissions-com.microsoft.skydrive.xml
system/priv-app/OneDrive_Samsung_v3
"

# Carrier app promotion/installers
# Exact directories used by the current y2s work dir (S721B EUX source).
PRISM_DEBLOAT+="
priv-app/appcloud_oobe_hutchison-release_V7.1.29.0
priv-app/appcloud_oobe_samsungGlobal_release
priv-app/appcloud_oobe_samsungOrange
priv-app/Ignite-telefonicaSamsungSamsungAgent_21.1.0-189_release-universal
priv-app/Ignite-aoneSamsungSamsungAgent_10.0.052-6492_release
priv-app/Ignite-timSamsungSamsungAgent_10.7.020-6760_release
priv-app/Ignite-bouyguesSamsungAgent_11.1.023-6793_release
priv-app/AppCenter
priv-app/CombinedStarter-16.00.00(160005783)-build_5783-Release-signed-aligned-pd
priv-app/MyApps-1.9.2-logoff-obson-prodSamsungRelease
priv-app/SFRJeux-9.2.2-logoff-obson-samsungRelease
"

# Amazon preload attribution and My Galaxy
PRISM_DEBLOAT+="
app/AmazonMDIP-release-signed-sdk34-Samsung
app/MDIP-TIM_O2UK_DTDE_VFAU_OPTUSAU_3IT-sdk34-111723
priv-app/MyGalaxy
"

# Samsung app provisioning, recommendations, customization and diagnostic/analytics uploaders
SYSTEM_DEBLOAT+="
system/app/MAPSAgent
system/priv-app/DiagMonAgent94
system/priv-app/DeviceQualityAgent35
system/priv-app/knoxanalyticsagent
system/etc/default-permissions/default-permissions-com.samsung.android.rubin.app.xml
system/etc/permissions/signature-permissions-com.samsung.android.rubin.app.xml
system/etc/permissions/privapp-permissions-com.samsung.android.rubin.app.xml
system/etc/permissions/privapp-permissions-com.sec.android.diagmonagent.xml
system/etc/permissions/privapp-permissions-com.samsung.android.dqagent.xml
system/etc/permissions/privapp-permissions-com.samsung.android.knox.analytics.uploader.xml
"

# Wi-Fi diagnostics, DSMS reports and Smart Suggestions
SYSTEM_DEBLOAT+="
system/app/WifiGuider
system/app/DsmsAPK
"

# eSIM
if $SOURCE_IS_ESIM_SUPPORTED; then
    if ! $TARGET_IS_ESIM_SUPPORTED; then
        SYSTEM_DEBLOAT+="
        system/etc/permissions/privapp-permissions-com.samsung.android.app.esimkeystring.xml
        system/etc/permissions/privapp-permissions-com.samsung.euicc.mep.xml
        system/etc/sysconfig/preinstalled-packages-com.samsung.android.app.esimkeystring.xml
        system/etc/sysconfig/preinstalled-packages-com.samsung.euicc.xml
        system/priv-app/EsimKeyString
        system/priv-app/EsimClient
        system/priv-app/EuiccService
        "
    fi
fi


# Wi-Fi Hotspot Overlays
PRODUCT_DEBLOAT+="
overlay/SoftapOverlay6GHz
overlay/SoftapOverlayDualAp
overlay/SoftapOverlayOWE
"

# StorageShare (kSMBd)
SYSTEM_DEBLOAT+="
"
