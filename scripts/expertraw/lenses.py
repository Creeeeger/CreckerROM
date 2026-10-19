# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later
"""Install device-specific RAW sizes in the pinned Expert RAW bytecode."""

import json
from pathlib import Path

DEVICES = ("r8s", "x1s", "y2s", "z3s", "c1s", "c2s")
RESOLUTION = "Lcom/samsung/android/app/galaxyraw/interfaces/Resolution;"
SETTINGS = "Lcom/samsung/android/app/galaxyraw/setting/repository/CameraSettingsImpl;"
# Expert RAW uses virtual rear IDs; Samsung exposes physical IDs 52 and 2.
CAMERAS = ("100", "101", "1", "3")


def load_profile(path, device):
    profile = json.loads(Path(path).read_text())
    if device not in DEVICES or profile.get("device") != device:
        raise ValueError(f"Expert RAW profile does not match device {device}: {path}")
    if not profile.get("models") or not all(
        model.startswith("SM-") for model in profile["models"]
    ):
        raise ValueError("Profile requires Samsung model identifiers")
    resolutions = profile.get("raw_resolutions", {})
    if set(resolutions) != set(CAMERAS):
        raise ValueError(
            "Profile requires primary tele, ultrawide, front and front crop RAW sizes"
        )
    for size in resolutions.values():
        if (
            not isinstance(size, list)
            or len(size) != 2
            or any(type(n) is not int for n in size)
        ):
            raise ValueError(f"Invalid RAW size: {size}")
        width, height = size
        if not (0 < width < 32768 and 0 < height < 32768) or width * 3 != height * 4:
            raise ValueError(f"Expected a supported 4:3 RAW size: {size}")
    flags = profile["set"]
    for flag, value in {
        "BACK_TELE_CAMERA_ID": "52",
        "BACK_WIDE_CAMERA_ID": "2",
        "FRONT_DYNAMIC_FOV_CAMERA_ID": "3",
        "BACK_SECOND_TELE_CAMERA_ID": "-1",
        "SUPPORT_BACK_TELE_PRO": "true",
        "SUPPORT_BACK_SECOND_TELE_PRO": "false",
        "SUPPORT_BACK_SECOND_TELE_CAMERA": "false",
    }.items():
        if flags.get(flag) != value:
            raise ValueError(f"Incorrect Exynos990 lens flag: {flag}")
    for flag, camera in {
        "BACK_WIDE_CAMERA_RESOLUTION_4BY3_LARGE": "101",
        "FRONT_CAMERA_RESOLUTION_4BY3_LARGE": "1",
        "FRONT_CAMERA_PICTURE_DEFAULT_RESOLUTION": "1",
        "FRONT_CAMERA_SENSOR_CROP_RESOLUTION_4BY3_LARGE": "3",
    }.items():
        if flags.get(flag) != "x".join(map(str, resolutions[camera])):
            raise ValueError(f"XML and RAW resolution disagree: {flag}")
    return profile


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError(f"Pinned Expert RAW smali anchor changed: {before[:100]}")
    return text.replace(before, after, 1)


def configure_smali(directory, profile):
    """Add resolution enums and select them by the app's camera IDs.

    RAW sizes come from each model's standard/vendor HAL stream tables. The
    same resolution selection controls output buffers, so using a JPEG-only
    crop size here would request a stream that the RAW camera cannot provide.
    """
    directory = Path(directory)
    resolution_path = (
        directory / "com/samsung/android/app/galaxyraw/interfaces/Resolution.smali"
    )
    settings_path = (
        directory
        / "com/samsung/android/app/galaxyraw/setting/repository/CameraSettingsImpl.smali"
    )
    resolution = resolution_path.read_text()
    settings = settings_path.read_text()
    fields, initializers, selection = [], [], []
    for index, camera in enumerate(CAMERAS):
        width, height = profile["raw_resolutions"][camera]
        name = f"RESOLUTION_EXYNOS_RAW_{camera}"
        enum_id = 0x7F00 + index
        fields.append(f".field public static final enum {name}:{RESOLUTION}\n")
        initializers.append(f'''
    array-length v2, v0
    add-int/lit8 v1, v2, 0x1
    invoke-static {{v0, v1}}, Ljava/util/Arrays;->copyOf([Ljava/lang/Object;I)[Ljava/lang/Object;
    move-result-object v8
    check-cast v8, [{RESOLUTION}
    new-instance v0, {RESOLUTION}
    const-string v1, "{name}"
    const/16 v3, 0x{enum_id:x}
    const/16 v4, 0x{width:x}
    const/16 v5, 0x{height:x}
    sget-object v6, Lcom/samsung/android/app/galaxyraw/interfaces/AspectRatio;->RATIO_4x3:Lcom/samsung/android/app/galaxyraw/interfaces/AspectRatio;
    const/16 v7, 0x1e
    invoke-direct/range {{v0 .. v7}}, {RESOLUTION}-><init>(Ljava/lang/String;IIIILcom/samsung/android/app/galaxyraw/interfaces/AspectRatio;I)V
    sput-object v0, {RESOLUTION}->{name}:{RESOLUTION}
    aput-object v0, v8, v2
    move-object v0, v8
''')
        selection.append(f"""
    const/16 v0, 0x{int(camera):x}
    if-ne p1, v0, :exynos_raw_next_{camera}
    const/16 v0, 0x{enum_id:x}
    return v0
    :exynos_raw_next_{camera}
""")
    resolution = replace_once(
        resolution, "# instance fields\n", "\n".join(fields) + "\n# instance fields\n"
    )
    anchor = f"    sput-object v0, {RESOLUTION}->$VALUES:[{RESOLUTION}\n"
    resolution = replace_once(
        resolution, anchor, anchor + "".join(initializers) + anchor
    )
    anchor = ".method public getCameraResolution(II)I\n    .locals 2\n"
    settings = replace_once(settings, anchor, anchor + "".join(selection))
    resolution_path.write_text(resolution)
    settings_path.write_text(settings)
