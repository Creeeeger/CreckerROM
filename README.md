> [!CAUTION]
> Before booting CreckerROM, **lock the bootloader** and wipe the `data`,
> `keystorage`, `keyrefuge`, and `metadata` partitions. These steps are mandatory
> and will erase all user data, so make a backup first.

> [!IMPORTANT]
> **Play Integrity Fix** is integrated and enabled by default. After flashing, use
> **Settings → Play Integrity Fix → Update Play Integrity Fix** to refresh the bundled spoofing profile;
> an external Play Integrity module is not required.

# Features

- Based on the latest stable OneUI 7 Galaxy S24 FE firmware
- All software features from S24 FE
- S25 Ultra CSC, ringtones and more
- Moderately Debloated
- Full SELinux Support
- Full Galaxy AI support
- Completely upstreamed kernels for all officially supported devices
- Now Brief Support
- Adaptive color tone support
- Super HDR support
- Adaptive Brightness support
- Full CSC support
- Adaptive Refresh Rate support (for some models)
- Multi-User support
- AppLock support
- EroFS partitions
- Stock models in Settings and user apps
- High end animations
- Native/live blur support
- Debloated from useless system services/additional apps
- [BluetoothLibraryPatcher](https://github.com/3arthur6/BluetoothLibraryPatcher) included
- Extra mods (Disable Secure Flag, OutDoor mode, more coming soon)
- Extra CSC features (Call recording, Network speed in status bar, 5GHz Hotspot)
- Countless other small optimizations

## CreckerROM-exclusive features and fixes

- Full custom AVB and Samsung signing for Exynos990, covering AP images, `vbmeta_samsung`, sparse `super`, the boot
  chain and rebuilt platform applications so locked-bootloader builds use one consistent signing identity
- Exact physical-model boot-chain support for every supported Exynos990 S20, S20 FE and Note20 variant, including
  correct BL1 metadata, rollback/RP revisions, LTE/5G runtime aliases and signed PIT handling
- Encrypted Exynos990 boot support with selectable encrypted or unencrypted builds
- Correct Exynos990 HIDL DRK path, restoring proper IMEI and device-identity reporting
- Working Samsung Cloud E2EE, Pass, Pay, Wallet, other Samsung services, Knox Guard and literally everything else broken
  before
- Crecker Kernel integration with preloaded KernelSU Next 3.2.0
- 100x photo and video zoom on supported Exynos990 devices
- S24 ICCC vendor stack with repaired fabric-crypto and FKeyM secure-world integration
- Preserved PROCA, Secure ADB, the OEM unlock toggle, target-aware StrongBox handling and the stock Knox services needed
  by Wallet-related components
- Built-in Play Integrity Fix with profile updates directly from Settings; no external PIF module is required
  (integrated with thanks to [salvogiangri](https://github.com/salvogiangri))
- Three debloat levels while preserving the applications and services required for messaging, Samsung accounts, firmware
  updates, Motion Photos, SIM unlocking and storage sharing
- S26 Ultra wallpaper resources integrated into the ROM
- Exact-model KVM/EL2 profiles and mode-specific Crecker Kernel builds for every supported Exynos990 model
- Model-labelled Odin and Heimdall output, plus signed rollback-firmware and kernel-only testing workflows

# Known bugs

- Samsung Log video recording at 4K 60 FPS and 8K 24 FPS is broken
- The camera feed flickers at high zoom levels (>40x) while recording video
- Live/Motion Photos can be captured, but their animated portion cannot be viewed in Samsung Gallery
- Passkey creation in Samsung Pass is broken because the FKeyMaster trusted application has not been ported yet; other
  passkey providers continue to work
- Factory reset from Android Settings does not work. Boot into TWRP through KernelSU or the hardware key combination and
  wipe the device from recovery instead

# Building

Set up the build environment, then start the build with `m`:

```sh
source ./buildenv.sh [options] <target>
m
```

## Exynos990 full-integrity startup

The locked-bootloader Exynos990 flow uses the
[CVE-2024-56426 repository](https://github.com/Creeeeger/CVE-2024-56426)
for the initial EUB and temporary signed boot-chain startup. Start its local control center before flashing a CreckerROM
build:

```sh
python3 exynos990_control_center.py
```

Select the exact physical model and the intended fuse profile. If the phone is not already in EUB, run **Flash Tampered
Loader / Enter EUB**, then run the temporary signed-chain step. The CVE control center establishes the bootloader path;
it does not replace flashing CreckerROM's complete generated package.

For a full-featured Samsung build, start CreckerROM from its repository root with `--no-debloat` in the
build-environment command. For example, the S20+
`G985F` command is:

```sh
source ./buildenv.sh --debug --official --encrypt --no-debloat --avb --avb-model G985F y2s
m
```

Replace both the AVB model and target codename for the physical device.
`--no-debloat` is required when the goal is to retain the complete available Samsung feature set: the normal and ultra
debloat profiles remove Samsung apps or services on which some features depend. The small essential compatibility list
is still applied.

### Exynos 990 KVM mode

Every supported Galaxy S20, S20 FE, and Note20 Exynos 990 target has an opt-in, exact-model EL2 boot profile for KVM.
Add `--kvm` with the physical phone's exact AVB model:

```sh
source ./buildenv.sh --kvm --avb-model G985F y2s
m
```

`--kvm` implies `--avb` and enables only the conditional LK H-Arx-removal, LK-to-EL3 SMC, and EL3-to-EL2 patch rows. The
kernel checkout fetches every remote branch and selects the first branch, sorted by ref name, whose name contains `kvm`
case-insensitively. A non-KVM build selects the stable
`OneUI7_8_stable` branch. KVM and rollback builds are mutually exclusive. Pair the resulting boot chain and kernel with
[WindowsInQemu](https://github.com/Creeeeger/WindowsInQemu) to run Windows in QEMU on the phone.

## Build-environment flags

| Flag                               | What it does                                                                                                                                                                                               | When to use it                                                                                                                     |
|------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|
| `--debug`                          | Enables verbose command and AVB diagnostic logging.                                                                                                                                                        | Troubleshooting a failed build or developing build-system changes.                                                                 |
| `--official`                       | Marks the generated configuration as an official build. This is the default in a clean shell.                                                                                                              | Release builds.                                                                                                                    |
| `--unofficial`                     | Marks the generated configuration as unofficial.                                                                                                                                                           | Local development and test builds.                                                                                                 |
| `--ext4-images`                    | Builds partitions configured for EROFS as ext4 instead. Partitions already requiring another filesystem keep their required format.                                                                        | Filesystem compatibility testing or debugging an EROFS-specific problem.                                                           |
| `--encrypt`                        | Enables the target's data-encryption/FBE configuration. Encryption is disabled by default.                                                                                                                 | Builds intended to use encrypted userdata. Format data when changing encryption state.                                             |
| `--debloat <default\|none\|ultra>` | Selects standard debloat, skips the normal debloat lists, or applies standard plus ultra debloat. The small essential list is always applied, including with `none`. `--debloat=<level>` is also accepted. | Use `none` for the complete available Samsung feature set; `default` and `ultra` intentionally remove additional components.       |
| `--no-debloat`                     | Alias for `--debloat none`.                                                                                                                                                                                | Required when the build is intended to retain all available Samsung features.                                                      |
| `--ultra-debloat`                  | Alias for `--debloat ultra`.                                                                                                                                                                               | Convenience for the smallest supported app set.                                                                                    |
| `--heimdall-only`                  | Disables Odin package creation and produces only the Heimdall flash folder.                                                                                                                                | Linux/Heimdall workflows or when individual flash images are required.                                                             |
| `--kernel-only`                    | Builds the kernel module and packages only signed `boot.img`, `dtbo.img`, and `vbmeta.img` in a Heimdall folder. It automatically enables AVB, Heimdall-only mode, and omits full partition descriptors.   | Fast kernel testing. Exynos990 targets still require the exact `--avb-model`.                                                      |
| `--avb`                            | Enables full custom AVB image signing, vbmeta generation, and the platform's bootloader-signing flow.                                                                                                      | Complete AVB builds intended for flashing.                                                                                         |
| `--avb-low-security`               | Enables AVB but skips partition-image footer signing and omits partition descriptors from vbmeta. It implies `--avb`.                                                                                      | Development and recovery testing only; do not use it for a normal release.                                                         |
| `--avb-model <model>`              | Selects the exact Exynos990 handset model and its BL1 signing metadata. `--avb-model=<model>` is also accepted.                                                                                            | Every AVB, low-security AVB, kernel-only, or rollback build for an Exynos990 target. Use the phone model, not the target codename. |
| `--kvm`                            | Enables the exact-model LK and EL3 monitor EL2 boot patches, selects the first remote branch containing `kvm`, and implies `--avb`.                                                                        | Supported for every listed Exynos990 model; cannot be combined with `--rollback`.                                                  |
| `--rollback`                       | Re-signs an old Exynos990 Odin firmware and replaces its recovery without running the custom-ROM modification flow. It implies AVB and Heimdall-only mode.                                                 | Creating a bootable rollback firmware set. Must be paired with `--rollback-firmware` and `--avb-model`.                            |
| `--rollback-firmware <name>`       | Selects an old downloaded firmware directory under `out/odin`, for example `SM-G985F_AUT`. `--rollback-firmware=<name>` is also accepted.                                                                  | Only with `--rollback`.                                                                                                            |
| `-h`, `--help`                     | Prints option help and the available target codenames.                                                                                                                                                     | Checking syntax or finding the correct target.                                                                                     |

The `m` command accepts `-f` or `--force`. A normal `m` invocation reuses the prepared work directory when its source
and build-affecting options have not changed; `m --force` rebuilds that work directory before creating fresh flash
packages.

## Common examples

Full AVB encrypted build for an exact Exynos990 model:

```sh
source ./buildenv.sh --debug --official --encrypt --no-debloat --avb --avb-model G985F y2s
m
```

AVB Heimdall-only build:

```sh
source ./buildenv.sh --avb --avb-model G985F --heimdall-only y2s
m
```

Signed kernel test images only:

```sh
source ./buildenv.sh --kernel-only --avb-model G985F y2s
m
```

Example G985F KVM build:

```sh
source ./buildenv.sh --kvm --avb-model G985F y2s
m
```

# Exynos990 TZAR / TZSW patching

When Samsung bootchain signing is enabled on Exynos990 targets:

- `TARGET_SAMSUNG_TZAR_PATCH_FILE` defaults to `/sbin/root_task`;
- `TARGET_SAMSUNG_TZAR_PATCH_TABLE` defaults to
  `security/samsung/patches/tzar_root_task_selected_patches.tsv`;
- `tzar.img` is unpacked, the selected member is patched from the TSV, and
  `tzar.img` is repacked and Stage-2 signed again;
- when `tzar.img` changes, encrypted `tzsw.img` is decrypted, userboot's embedded `startup.tzar` object hash table is
  patched, `tzsw.img` is re-encrypted with a refreshed `BiEn` digest, and `tzsw.img` is Stage-2 signed again. Set
  `TARGET_SAMSUNG_DECRYPTED_TZSW_PATH` only when you want to override the stock
  `tzsw.img` source used for that step.

# Exynos990 BL1 model selection

AVB-enabled Exynos990 builds require the exact phone model so the regenerated
`fwbl1.img` uses the correct Samsung BL1 signing tag:

```sh
source ./buildenv.sh --avb --avb-model G981B x1s
```

The supported values and metadata extracted from stock firmware are shown below. Rollback revisions are decimal values
and are applied to both AVB and Samsung signatures.

| Model flag | Runtime artifact | Runtime firmware | Model ID | EVT  | Rollback |
|------------|------------------|------------------|----------|------|----------|
| `G780F`    | `G780F`          | `G780FXXSOFYJ1`  | `0x154`  | `11` | `24`     |
| `G980F`    | `G981B`          | `G981BXXSNHYB1`  | `0x143`  | `11` | `23`     |
| `G981B`    | `G981B`          | `G981BXXSNHYB1`  | `0x13D`  | `11` | `23`     |
| `G985F`    | `G986B`          | `G986BXXSNHYB1`  | `0x142`  | `11` | `23`     |
| `G986B`    | `G986B`          | `G986BXXSNHYB1`  | `0x13C`  | `11` | `23`     |
| `G988B`    | `G988B`          | `G988BXXSNHYB1`  | `0x13E`  | `11` | `23`     |
| `N980F`    | `N981B`          | `N981BXXSIHYH3`  | `0x153`  | `11` | `18`     |
| `N981B`    | `N981B`          | `N981BXXSIHYH3`  | `0x14E`  | `11` | `18`     |
| `N985F`    | `N986B`          | `N986BXXSIHYH3`  | `0x152`  | `11` | `18`     |
| `N986B`    | `N986B`          | `N986BXXSIHYH3`  | `0x14D`  | `11` | `18`     |

# Exynos990 rollback firmware builds

Rollback mode re-signs an old downloaded Odin firmware without running the normal custom-ROM extraction, module, or
patch flow. It preserves opaque image contents, unpacks only the logical partitions in `super.img`, replaces stock
recovery with the target TWRP image, and uses the configured target firmware as the source for the patched `sboot.bin`.

```sh
source ./buildenv.sh --rollback \
    --rollback-firmware SM-G985F_AUT \
    --avb-model G985F y2s
```

The Heimdall folder is written to
`out/rollback_SM-G985F_AUT_y2s-heimdall`. It includes the re-signed images,
`flash_all.sh`, and `sha256sums.txt`.

Re-signing updates the required Samsung and AVB rollback metadata, but it does not make very old secure-world components
compatible with the newer boot chain. If every signature and RP check passes but the firmware still does not boot, use a
newer donor firmware from the desired Android generation. In one tested G985F case, the first Android 10/revision-1
firmware initialized H-Arx but H-Arx rejected `uh.bin` with return `0x51002` and continued without the UH plug-in. The
last Android 10/revision-5 firmware registered the UH plug-in and booted successfully with the same revision-23
`sboot.bin` chain.

# Licensing

This project is licensed under the terms of the [GNU General Public License v3.0](LICENSE). External dependencies might
be distributed under a different license, such as:

- [android-tools](https://github.com/nmeum/android-tools), licensed under
  the [Apache License 2.0](https://github.com/nmeum/android-tools/blob/master/LICENSE)
- [apktool](https://github.com/iBotPeaches/Apktool), licensed under
  the [Apache License 2.0](https://github.com/iBotPeaches/Apktool/blob/master/LICENSE.md)
- [erofs-utils](https://github.com/sekaiacg/erofs-utils/), dual license
  ([GPL-2.0](https://github.com/sekaiacg/erofs-utils/blob/dev/LICENSES/GPL-2.0), [Apache-2.0](https://github.com/sekaiacg/erofs-utils/blob/dev/LICENSES/Apache-2.0))
- [img2sdat](https://github.com/xpirt/img2sdat), licensed under
  the [MIT License](https://github.com/xpirt/img2sdat/blob/master/LICENSE)
- [platform_build](https://android.googlesource.com/platform/build/) (ext4_utils, f2fs_utils, signapk), licensed under
  the [Apache License 2.0](https://source.android.com/docs/setup/about/licenses)
- [smali](https://github.com/google/smali), [multiple licenses](https://github.com/google/smali/blob/main/third_party/NOTICE)

# Accountability

```cpp
#include <std_disclaimer.h>

/*
* Your warranty is now void.
*
* I am not responsible for bricked devices, dead SD cards,
* thermonuclear war, or you getting fired because the alarm app failed. Please
* do some research if you have any concerns about doing this to your device
* YOU are choosing to make these modifications, and if
* you point the finger at me for messing up your device, I will laugh at you.
*
* I am also not responsible for you getting in trouble for using any of the
* features in this ROM, including but not limited to Call Recording, secure
* flag removal etc.
*/
```

# Credits

A big thanks goes to the following for their invaluable contributions in no particular order (MORE INFO AND PEOPLE: TO
BE WRITTEN)

- **[salvogiangri](https://github.com/salvogiangri)** for the UN1CA build system, OneUI patches, and general help and
  support while developing
- **[Ocin4Ever](https://github.com/Ocin4Ever)** for a lot of help especially on smali, advice and emotional support :D
- **[Igor](https://github.com/BotchedRPR)** for getting me into porting, teaching me the basics, and emotional support
  down the road
- **[Halal Beef](https://github.com/halal-beef)** for lk3rd, testing and misc help
- **[Emad](https://github.com/emadhamid7)** for help with S10-specific fixes
- **[Duhan](https://github.com/duhansysl)** for help with vendor backports, a lot of fixes and advice
- **[Anan](https://github.com/ananjaser1211)** for all of his contributions to OneUI porting
- **[PeterKnecht93](https://github.com/PeterKnecht93)** for help with smali and a lot of misc fixes
- **[tsn](https://github.com/tisenu100)** for some smali fixes and advice
- **[Nguyen Long](https://github.com/LumiPlayground)** for misc fixes and support
- **[AlexFurina](https://github.com/AlexFurina)** for S10 specific fixes
- **[Luphaestus](https://github.com/Luphaestus)** for Note 20 specific fixes
- **[Yagzie](https://github.com/Yagzie)** for engmode and misc fixes
- **[Fred](https://github.com/xfwdrev)** for WFD, HDR10+, audiopolicy and more fixes
- **[Saad](https://github.com/saadelasfur)** for help with build system
- **[Vince](https://github.com/borbelyvince)** for help with kernel upstream
- **Nhat Vo** for Google Telemetry app removal
- **[Code Malaya](https://github.com/jomiejoshiro)** for SPen Air Actions
- **[Renox](https://github.com/renoxtv)** for overlay patches and testing
- **[Ksawlii](https://github.com/Ksawlii)** for updating the build system and FOD animation patch
- **[nalz0](https://github.com/nalz0)** for Multi-User support
- **[EndaDwagon](https://github.com/EndaDwagon)** for the big majority of the ExtremeROM Wiki
- **[Oskar](https://github.com/osrott61-gh)** for Odinpacks, Building before we started using CI, Wiki
- **[Mesazane](https://github.com/Mesazane)** for Building before we started using CI
- **[Dupa](https://github.com/dupazlasu)** for Maintaining S22 Series (ROM + Kernel)
- **[RayShocker](https://github.com/RayShocker)** for HRM fix
- **[Szucsy92](https://github.com/Szucsy92)** for SingleTake fix
- **[Kurt](https://github.com/kurtbahartr)** for ASCII art and some minor fixes
- **@april865** (TG) for ExtremeROM Nexus banner
- And everyone else who aided in testing, wiki, translations etc!

Original UN1CA credits:

- **[ShaDisNX255](https://github.com/ShaDisNX255)** for his help, time and for
  his [NcX ROM](https://github.com/ShaDisNX255/NcX_Stock) which inspired this project
- **[DavidArsene](https://github.com/DavidArsene)** for his help and time
- **[paulowesll](https://github.com/paulowesll)** for his help and support
- **[Simon1511](https://github.com/Simon1511)** for his support and some of the device-specific patches
- **[ananjaser1211](https://github.com/ananjaser1211)** for troubleshooting and his time
- **[iDrinkCoffee](https://github.com/iDrinkCoffee-TG)** and **[RisenID](https://github.com/RisenID)** for documentation
  revisioning
- **[LineageOS Team](https://www.lineageos.org/)** for their
  original [OTA updater implementation](https://github.com/LineageOS/android_packages_apps_Updater)
- *All the UN1CA project contributors and testers ❤️*

# Kernel sources and device trees

- 990 Kernel Source Code (Maintainer: @Creeeeger): https://github.com/Creeeeger/exynos990Kernel
- 990 Device Tree Code (Maintainer: @ExtremeXT): https://github.com/ExtremeXT/android_device_samsung_exynos9820
- 2100 Kernel Source Code (Maintainer: @xfwdrev/@maximusXZ): https://github.com/xfwdrev/android_kernel_samsung_ex2100
- 2100 Device Tree Code (Maintainer: @xfwdrev/@maximusXZ): https://github.com/xfwdrev/android_device_samsung_exynos2100
- 2200 Kernel Source Code (Maintainer: @dupazlasu): https://github.com/ExtremeXT/android_kernel_samsung_s5e9925
- 2200 Device Tree Code (Maintainer: @dupazlasu): https://github.com/dupazlasu/android_device_samsung_s5e9925
