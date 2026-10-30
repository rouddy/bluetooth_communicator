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

    buildFeatures {
        aidl = true
    }

    // The communicator's AIDL interface, compiled from its own sources so the two
    // apps can't drift apart.
    sourceSets {
        getByName("main") {
            aidl.directories.add("../../android/app/src/main/aidl")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
