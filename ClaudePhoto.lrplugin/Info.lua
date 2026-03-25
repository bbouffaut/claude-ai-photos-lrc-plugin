return {
    LrSdkVersion = 6.0,
    LrSdkMinimumVersion = 5.0,

    LrToolkitIdentifier = 'com.claudephoto.lightroom',
    LrPluginName = LOC "$$$/ClaudePhoto/PluginName=Claude Photo AI",

    LrLibraryMenuItems = {
        {
            title = LOC "$$$/ClaudePhoto/Menu/Develop=Développer avec Claude AI",
            file = "ClaudePhotoMain.lua",
        },
    },

    LrExportMenuItems = {
        {
            title = LOC "$$$/ClaudePhoto/Menu/Export=Appliquer réglages Claude AI",
            file = "ClaudePhotoMain.lua",
        },
    },

    VERSION = { major=1, minor=0, revision=0, build=1 },
}
