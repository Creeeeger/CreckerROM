.class public Lio/mesalabs/unica/settings/pif/PIFSettingsFragment;
.super Lcom/android/settings/dashboard/DashboardFragment;
.source "PIFSettingsFragment.java"


# direct methods
.method public constructor <init>()V
    .locals 0

    invoke-direct {p0}, Lcom/android/settings/dashboard/DashboardFragment;-><init>()V

    return-void
.end method

.method public static buildPreferenceControllers(Landroid/content/Context;Landroidx/fragment/app/Fragment;)Ljava/util/List;
    .locals 3

    new-instance v0, Ljava/util/ArrayList;

    invoke-direct {v0}, Ljava/util/ArrayList;-><init>()V

    new-instance v1, Lio/mesalabs/unica/settings/pif/PIFCustomPreferenceController;

    const-string v2, "unica_pif_custom"

    invoke-direct {v1, p0, v2, p1}, Lio/mesalabs/unica/settings/pif/PIFCustomPreferenceController;-><init>(Landroid/content/Context;Ljava/lang/String;Landroidx/fragment/app/Fragment;)V

    invoke-virtual {v0, v1}, Ljava/util/ArrayList;->add(Ljava/lang/Object;)Z

    return-object v0
.end method


# virtual methods
.method public final createPreferenceControllers(Landroid/content/Context;)Ljava/util/List;
    .locals 0

    invoke-static {p1, p0}, Lio/mesalabs/unica/settings/pif/PIFSettingsFragment;->buildPreferenceControllers(Landroid/content/Context;Landroidx/fragment/app/Fragment;)Ljava/util/List;

    move-result-object p0

    return-object p0
.end method

.method public final getLogTag()Ljava/lang/String;
    .locals 0

    const-string p0, "PIFSettingsFragment"

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

    const-string v1, "unica_pif_settings"

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

