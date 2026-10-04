# Original features by Salvo Giangreco / UN1CA, adapted for One UI 7.
# SPDX-License-Identifier: GPL-3.0-or-later

LOG_STEP_IN "- Adding UN1CA feature controls (thanks to salvogiangri)"

DECODE_APK "system" "system/priv-app/SecSettings/SecSettings.apk"

# These resources have distinct filenames. Keep the existing Settings and PIF
# resources intact; the accompanying smali patches extend their shared helper.
cp -a "$MODPATH/SecSettings.apk/." \
    "$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk/"

python3 - "$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk" <<'PY'
from pathlib import Path
import sys

homepage = Path(sys.argv[1]) / "res/xml/sec_top_level_settings.xml"
text = homepage.read_text()
if 'android:key="top_level_unica_features"' not in text:
    closing = "</PreferenceScreen>"
    if text.count(closing) != 1:
        raise SystemExit("Cannot find the Settings homepage insertion point")
    entry = (
        '    <com.android.settings.widget.HomepagePreference '
        'android:icon="@drawable/sec_ic_settings_biometrics_and_security" '
        'android:title="@string/unica_features_title" '
        'android:key="top_level_unica_features" '
        'android:summary="@string/unica_features_summary" '
        'android:order="-39998" '
        'android:fragment="io.mesalabs.unica.settings.UnicaFeaturesFragment" />\n'
    )
    homepage.write_text(text.replace(closing, entry + closing))
PY

LOG_STEP_OUT
