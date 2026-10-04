# Original features: Salvo Giangreco / UN1CA (GPL-3.0-or-later).
.class public Lio/mesalabs/unica/settings/UnicaFeaturesFragment;
.super Lcom/android/settings/dashboard/DashboardFragment;
.source "UnicaFeaturesFragment.java"


# direct methods
.method public constructor <init>()V
    .locals 0

    invoke-direct {p0}, Lcom/android/settings/dashboard/DashboardFragment;-><init>()V

    return-void
.end method




# virtual methods


.method public final getLogTag()Ljava/lang/String;
    .locals 0

    const-string p0, "UnicaFeaturesFragment"

    return-object p0
.end method

.method public final getMetricsCategory()I
    .locals 0

    const/16 p0, 0x2e8

    return p0
.end method

.method public final getPreferenceScreenResId()I
    .locals 2

    const-string v0, "xml"

    const-string v1, "unica_features_settings"

    invoke-static {v0, v1}, Lio/mesalabs/unica/utils/Utils;->getResourceId(Ljava/lang/String;Ljava/lang/String;)I

    move-result p0

    return p0
.end method

.method public final onCreate(Landroid/os/Bundle;)V
    .locals 1

    invoke-super {p0, p1}, Lcom/android/settings/dashboard/DashboardFragment;->onCreate(Landroid/os/Bundle;)V

    const/4 v0, 0x1

    invoke-virtual {p0, v0}, Lcom/android/settings/SettingsPreferenceFragment;->setAnimationAllowed(Z)V

    return-void
.end method

