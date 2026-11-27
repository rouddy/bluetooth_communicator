plugins {
    id("com.android.application")
}

android {
    namespace = "com.rouddy.bluetooth_communicator.testapp"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.rouddy.bluetooth_communicator.testapp"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // The communicator's AIDL interface and BleApi (settings.gradle.kts).
    implementation(project(":ble-api"))
}
