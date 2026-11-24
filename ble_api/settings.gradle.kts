// ble-api on its own, for publishing (.github/workflows/ble-api.yml). The
// communicator (android/) and test_app include this directory as their :ble-api
// project instead, so they always build the current AIDL; this file isn't read then.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    // build.gradle.kts can't name a version: in the other two builds the plugin is
    // already on the classpath.
    plugins {
        id("com.android.library") version "9.3.1"
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "ble-api"
