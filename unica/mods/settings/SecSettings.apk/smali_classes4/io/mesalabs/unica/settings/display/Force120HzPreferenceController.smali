.class public final Lio/mesalabs/unica/settings/display/Force120HzPreferenceController;
.super Ljava/lang/Object;
.source "Force120HzPreferenceController.java"

.implements Landroidx/preference/Preference$OnPreferenceChangeListener;

.field private final mFragment:Lcom/samsung/android/settings/display/HighRefreshRateFragment;

.field private final mPreference:Landroidx/preference/SecSwitchPreference;

.method public constructor <init>(Lcom/samsung/android/settings/display/HighRefreshRateFragment;)V
    .locals 1

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lio/mesalabs/unica/settings/display/Force120HzPreferenceController;->mFragment:Lcom/samsung/android/settings/display/HighRefreshRateFragment;

    const-string v0, "crecker_force_120hz"

    invoke-virtual {p1, v0}, Lcom/android/settings/core/InstrumentedPreferenceFragment;->findPreference(Ljava/lang/CharSequence;)Landroidx/preference/Preference;

    move-result-object p1

    check-cast p1, Landroidx/preference/SecSwitchPreference;

    iput-object p1, p0, Lio/mesalabs/unica/settings/display/Force120HzPreferenceController;->mPreference:Landroidx/preference/SecSwitchPreference;

    invoke-virtual {p1, p0}, Landroidx/preference/Preference;->setOnPreferenceChangeListener(Landroidx/preference/Preference$OnPreferenceChangeListener;)V

    return-void
.end method

.method public static isEnabled(Landroid/content/Context;)Z
    .locals 2

    invoke-virtual {p0}, Landroid/content/Context;->getContentResolver()Landroid/content/ContentResolver;

    move-result-object p0

    const-string v0, "crecker_force_120hz"

    const/4 v1, 0x0

    invoke-static {p0, v0, v1}, Landroid/provider/Settings$Secure;->getInt(Landroid/content/ContentResolver;Ljava/lang/String;I)I

    move-result p0

    if-eqz p0, :disabled

    const/4 v1, 0x1

    :disabled
    return v1
.end method

.method public onPreferenceChange(Landroidx/preference/Preference;Ljava/lang/Object;)Z
    .locals 6

    check-cast p2, Ljava/lang/Boolean;

    invoke-virtual {p2}, Ljava/lang/Boolean;->booleanValue()Z

    move-result p2

    iget-object v0, p0, Lio/mesalabs/unica/settings/display/Force120HzPreferenceController;->mFragment:Lcom/samsung/android/settings/display/HighRefreshRateFragment;

    iget-object v1, v0, Lcom/samsung/android/settings/display/HighRefreshRateFragment;->mContext:Landroid/content/Context;

    invoke-static {v1}, Lio/mesalabs/unica/settings/display/Force120HzPreferenceController;->isEnabled(Landroid/content/Context;)Z

    move-result v2

    const/4 v3, 0x1

    if-eq p2, v2, :done

    invoke-virtual {v1}, Landroid/content/Context;->getContentResolver()Landroid/content/ContentResolver;

    move-result-object p1

    const-string v2, "refresh_rate_mode"

    const-string v4, "crecker_force_120hz_previous_mode"

    const-string v5, "crecker_force_120hz"

    if-eqz p2, :disable

    # Preserve the exact previous mode, including an unset value. Minimum
    # and peak refresh settings remain untouched; the service owns the vote.
    invoke-static {p1, v2}, Landroid/provider/Settings$Secure;->getString(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v2

    invoke-static {p1, v4, v2}, Landroid/provider/Settings$Secure;->putString(Landroid/content/ContentResolver;Ljava/lang/String;Ljava/lang/String;)Z

    move-result v2

    if-eqz v2, :failed

    const/16 v2, 0x3e7

    invoke-static {v2}, Lcom/samsung/android/settings/display/SecDisplayUtils;->getHighRefreshRateSeamlessType(I)I

    move-result v4

    if-ne v4, v3, :seamless

    const/4 v4, 0x2

    goto :set_mode

    :seamless
    move v4, v3

    :set_mode
    invoke-static {v1, v4, v2}, Lcom/samsung/android/settings/display/SecDisplayUtils;->putIntRefreshRate(Landroid/content/Context;II)V

    invoke-static {p1, v5, v3}, Landroid/provider/Settings$Secure;->putInt(Landroid/content/ContentResolver;Ljava/lang/String;I)Z

    move-result v3

    goto :refresh

    :disable
    const/4 v3, 0x0

    invoke-static {p1, v5, v3}, Landroid/provider/Settings$Secure;->putInt(Landroid/content/ContentResolver;Ljava/lang/String;I)Z

    move-result v3

    if-eqz v3, :failed

    invoke-static {p1, v4}, Landroid/provider/Settings$Secure;->getString(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v5

    invoke-static {p1, v2, v5}, Landroid/provider/Settings$Secure;->putString(Landroid/content/ContentResolver;Ljava/lang/String;Ljava/lang/String;)Z

    move-result v3

    const/4 v2, 0x0

    invoke-static {p1, v4, v2}, Landroid/provider/Settings$Secure;->putString(Landroid/content/ContentResolver;Ljava/lang/String;Ljava/lang/String;)Z

    :refresh
    const/16 v2, 0x3e7

    invoke-static {v1, v2}, Lcom/samsung/android/settings/display/SecDisplayUtils;->getIntRefreshRate(Landroid/content/Context;I)I

    move-result v2

    iput v2, v0, Lcom/samsung/android/settings/display/HighRefreshRateFragment;->mMode:I

    invoke-virtual {v0}, Lcom/samsung/android/settings/display/HighRefreshRateFragment;->refreshUI$3()V

    :done
    return v3

    :failed
    const/4 v3, 0x0

    return v3
.end method

.method public updateState()V
    .locals 7

    iget-object v0, p0, Lio/mesalabs/unica/settings/display/Force120HzPreferenceController;->mFragment:Lcom/samsung/android/settings/display/HighRefreshRateFragment;

    iget-object v1, p0, Lio/mesalabs/unica/settings/display/Force120HzPreferenceController;->mPreference:Landroidx/preference/SecSwitchPreference;

    const/16 v2, 0x3e7

    invoke-static {v2}, Lcom/samsung/android/settings/display/SecDisplayUtils;->getHighRefreshRateSupportedValues(I)[Ljava/lang/String;

    move-result-object v2

    invoke-static {v2}, Ljava/util/Arrays;->asList([Ljava/lang/Object;)Ljava/util/List;

    move-result-object v2

    const-string v3, "120"

    invoke-interface {v2, v3}, Ljava/util/List;->contains(Ljava/lang/Object;)Z

    move-result v2

    invoke-virtual {v1, v2}, Landroidx/preference/Preference;->setVisible(Z)V

    iget-object v2, v0, Lcom/samsung/android/settings/display/HighRefreshRateFragment;->mContext:Landroid/content/Context;

    invoke-static {v2}, Lio/mesalabs/unica/settings/display/Force120HzPreferenceController;->isEnabled(Landroid/content/Context;)Z

    move-result v3

    invoke-virtual {v1, v3}, Landroidx/preference/TwoStatePreference;->setChecked(Z)V

    iget v4, v0, Lcom/samsung/android/settings/display/HighRefreshRateFragment;->mFlags:I

    const/4 v5, 0x1

    if-nez v3, :enabled

    if-eqz v4, :enabled

    const/4 v5, 0x0

    :enabled
    invoke-virtual {v1, v5}, Landroidx/preference/Preference;->setEnabled(Z)V

    const-string v5, "crecker_force_120hz_summary"

    and-int/lit8 v6, v4, 0x1

    if-eqz v6, :summary

    const-string v5, "crecker_force_120hz_resolution_summary"

    :summary
    const-string v6, "string"

    invoke-static {v6, v5}, Lio/mesalabs/unica/utils/Utils;->getResourceId(Ljava/lang/String;Ljava/lang/String;)I

    move-result v5

    invoke-virtual {v1, v5}, Landroidx/preference/Preference;->setSummary(I)V

    if-eqz v3, :done

    # Prevent the ordinary radio buttons and Apply from contradicting the
    # fixed mode. The switch can always be turned off, even while limited.
    const/4 v3, 0x0

    iget-object v1, v0, Lcom/samsung/android/settings/display/HighRefreshRateFragment;->mPowerfulMode:Lcom/samsung/android/settings/widget/SecRadioButtonPreference;

    invoke-virtual {v1, v3}, Landroidx/preference/Preference;->setEnabled(Z)V

    iget-object v1, v0, Lcom/samsung/android/settings/display/HighRefreshRateFragment;->mNormalMode:Lcom/samsung/android/settings/widget/SecRadioButtonPreference;

    invoke-virtual {v1, v3}, Landroidx/preference/Preference;->setEnabled(Z)V

    iget-object v1, v0, Lcom/samsung/android/settings/display/HighRefreshRateFragment;->mApplyButton:Lcom/samsung/android/settings/widget/SecButtonPreference;

    invoke-virtual {v1, v3}, Landroidx/preference/Preference;->setEnabled(Z)V

    :done
    return-void
.end method
