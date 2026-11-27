pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "test_app"
include(":app")

// The communicator's AIDL interface and BleApi, built from source so the two apps
// can't drift apart. Other apps use the published com.rouddy.bluetooth_communicator:
// ble-api instead (ble_api/README.md).
include(":ble-api")
project(":ble-api").projectDir = file("../ble_api")
