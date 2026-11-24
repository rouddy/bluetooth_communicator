import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (docs/release.md): android/key.properties names the Play upload
// keystore. CI writes it from secrets. Without it, release builds are signed with the
// debug key as before, so `flutter run --release` still works on a dev machine.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) {
        file.inputStream().use(::load)
    }
}

android {
    namespace = "com.rouddy.bluetooth_communicator.bluetooth_communicator"
    // permission_handler_android 14.x requires compiling against API 37. This only
    // affects which APIs are visible at compile time; runtime behavior follows targetSdk.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.rouddy.bluetooth_communicator.bluetooth_communicator"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 12 (API 31) is the floor: the BLE runtime permissions
        // (BLUETOOTH_SCAN/CONNECT/ADVERTISE) replace the location-based model below it.
        minSdk = 31
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (!keystoreProperties.isEmpty) {
            create("release") {
                // Relative to android/.
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // The AIDL service other apps bind to (docs/protocol.md 11절), and BleApi.
    implementation(project(":ble-api"))
    testImplementation("junit:junit:4.13.2")
    // A real org.json for JVM tests (android.jar's is a stub); reads test_vectors/.
    testImplementation("org.json:json:20250517")
}
