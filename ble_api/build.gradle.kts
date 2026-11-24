import java.security.MessageDigest
import java.util.Properties

// The communicator's AIDL interface (docs/protocol.md 11절) and BleApi, which tells
// an app whether its copy and the installed communicator's can talk. Built as the
// :ble-api project of the communicator (android/) and test_app, and published on
// its own to GitHub Packages (README.md).
plugins {
    id("com.android.library")
    `maven-publish`
}

group = "com.rouddy.bluetooth_communicator"
version = findProperty("bleApi.version") as String

// What the AIDL says about itself, worked out while the build is configured and
// compiled into BleApiInfo and the manifest's <meta-data>.
val aidlDir = file("src/main/aidl")
val bleApiVersion: Int = Regex("""\bconst\s+int\s+API_VERSION\s*=\s*(\d+)\s*;""")
    .find(aidlDir.resolve("com/rouddy/bluetooth_communicator/api/IBleCommunicator.aidl").readText())
    ?.groupValues?.get(1)?.toInt()
    ?: error("No API_VERSION in IBleCommunicator.aidl")
val bleApiMinVersion: Int = (findProperty("bleApi.minCompatibleVersion") as String).toInt()
val bleApiHash: String = aidlHash(aidlDir)
val frozenApi = file("frozen-api.properties")

check(version.toString().substringBefore('.') == bleApiVersion.toString()) {
    "bleApi.version $version doesn't start with API_VERSION $bleApiVersion"
}

android {
    namespace = "com.rouddy.bluetooth_communicator.api"
    compileSdk = 36

    defaultConfig {
        minSdk = 21
        // src/main/AndroidManifest.xml: what the other side's BleApi reads.
        manifestPlaceholders["bleApiVersion"] = bleApiVersion.toString()
        manifestPlaceholders["bleApiMinCompatibleVersion"] = bleApiMinVersion.toString()
        manifestPlaceholders["bleApiHash"] = bleApiHash
    }

    buildFeatures {
        aidl = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

androidComponents {
    onVariants { variant ->
        val generate = tasks.register<GenerateBleApiInfo>(
            "generate${variant.name.replaceFirstChar(Char::uppercase)}BleApiInfo"
        ) {
            minCompatibleVersion.set(bleApiMinVersion)
            apiHash.set(bleApiHash)
        }
        variant.sources.java?.addGeneratedSourceDirectory(generate, GenerateBleApiInfo::outputDir)
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

val checkBleApi = tasks.register<CheckBleApi>("checkBleApi") {
    group = "verification"
    description = "Fails if the AIDL changed under an API_VERSION that was already frozen."
    apiVersion.set(bleApiVersion)
    apiHash.set(bleApiHash)
    frozenFile.set(frozenApi)
    requireFrozen.set(false)
}
val checkBleApiFrozen = tasks.register<CheckBleApi>("checkBleApiFrozen") {
    group = "verification"
    description = "checkBleApi, and fails if API_VERSION isn't frozen yet (release builds)."
    apiVersion.set(bleApiVersion)
    apiHash.set(bleApiHash)
    frozenFile.set(frozenApi)
    requireFrozen.set(true)
}
tasks.register<FreezeBleApi>("freezeBleApi") {
    description = "Records API_VERSION's hash in frozen-api.properties, before releasing it."
    apiVersion.set(bleApiVersion)
    apiHash.set(bleApiHash)
    frozenFile.set(frozenApi)
}
tasks.register("bleApiInfo") {
    description = "Prints API_VERSION, the oldest compatible version, and the AIDL hash."
    val info = "API_VERSION=$bleApiVersion minCompatibleVersion=$bleApiMinVersion hash=$bleApiHash"
    doLast { println(info) }
}

// Every build checks; a release build (and so publishing, and the communicator's
// release APK) also needs the version frozen, so what ships is what was frozen.
tasks.configureEach {
    when (name) {
        "preBuild" -> dependsOn(checkBleApi)
        "preReleaseBuild" -> dependsOn(checkBleApiFrozen)
    }
}

publishing {
    publications {
        register<MavenPublication>("release") {
            artifactId = "ble-api"
            afterEvaluate {
                from(components["release"])
            }
            pom {
                name.set("Bluetooth Communicator API")
                description.set(
                    "The AIDL interface of Bluetooth Communicator, and a check that the installed " +
                        "communicator speaks it."
                )
                url.set("https://github.com/rouddy/bluetooth_communicator")
            }
        }
    }
    repositories {
        maven {
            name = "GitHubPackages"
            url = uri("https://maven.pkg.github.com/rouddy/bluetooth_communicator")
            // The GitHubPackagesUsername and GitHubPackagesPassword properties (the
            // workflow passes its GITHUB_TOKEN).
            credentials(PasswordCredentials::class)
        }
    }
}

/**
 * SHA-256 of the AIDL files under [dir], by path, in the form [normalizeAidl] gives
 * them: comments and formatting don't change it, anything the compiler reads does.
 */
fun aidlHash(dir: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    dir.walkTopDown()
        .filter { it.isFile && it.extension == "aidl" }
        .map { it.relativeTo(dir).invariantSeparatorsPath to it }
        .sortedBy { it.first }
        .forEach { (path, file) -> digest.update("$path\n${normalizeAidl(file.readText())}\n".toByteArray()) }
    return digest.digest().joinToString("") { "%02x".format(it) }
}

/** [text] without comments, with a space only where it separates two words. */
fun normalizeAidl(text: String): String {
    val out = StringBuilder()
    var gap = false
    fun emit(token: String) {
        if (gap && out.isNotEmpty() && isWordChar(out.last()) && isWordChar(token.first())) {
            out.append(' ')
        }
        out.append(token)
        gap = false
    }
    var i = 0
    while (i < text.length) {
        when {
            text[i] == '"' -> {
                var end = i + 1
                while (end < text.length && text[end] != '"') {
                    end += if (text[end] == '\\') 2 else 1
                }
                end = minOf(end + 1, text.length)
                emit(text.substring(i, end))
                i = end
            }
            text.startsWith("//", i) -> {
                i = text.indexOf('\n', i).let { if (it < 0) text.length else it }
                gap = true
            }
            text.startsWith("/*", i) -> {
                i = text.indexOf("*/", i + 2).let { if (it < 0) text.length else it + 2 }
                gap = true
            }
            text[i].isWhitespace() -> {
                gap = true
                i++
            }
            else -> emit(text[i++].toString())
        }
    }
    return out.toString()
}

fun isWordChar(c: Char) = c.isLetterOrDigit() || c == '_'

/** Writes BleApiInfo.java, the values BleApi compiles in. */
abstract class GenerateBleApiInfo : DefaultTask() {
    @get:Input
    abstract val minCompatibleVersion: Property<Int>

    @get:Input
    abstract val apiHash: Property<String>

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun generate() {
        val dir = outputDir.get().asFile.resolve("com/rouddy/bluetooth_communicator/api")
        dir.mkdirs()
        dir.resolve("BleApiInfo.java").writeText(
            """
            |// Generated by ble_api/build.gradle.kts from src/main/aidl and gradle.properties.
            |package com.rouddy.bluetooth_communicator.api;
            |
            |final class BleApiInfo {
            |    static final int MIN_COMPATIBLE_VERSION = ${minCompatibleVersion.get()};
            |    static final String HASH = "${apiHash.get()}";
            |
            |    private BleApiInfo() {
            |    }
            |}
            |""".trimMargin()
        )
    }
}

/**
 * Fails when the AIDL changed under an API_VERSION that frozen-api.properties
 * already has, and with [requireFrozen], when it doesn't have it yet.
 */
abstract class CheckBleApi : DefaultTask() {
    @get:Input
    abstract val apiVersion: Property<Int>

    @get:Input
    abstract val apiHash: Property<String>

    @get:Input
    abstract val requireFrozen: Property<Boolean>

    @get:InputFile
    abstract val frozenFile: RegularFileProperty

    @TaskAction
    fun check() {
        val file = frozenFile.get().asFile
        val frozen = Properties().apply { file.inputStream().use(::load) }
        val version = apiVersion.get()
        val expected = frozen.getProperty(version.toString())
        if (expected != null && expected != apiHash.get()) {
            throw GradleException(
                "The AIDL in ble_api/src/main/aidl changed, but API_VERSION $version was already " +
                    "frozen with another interface (${file.name}). Raise API_VERSION in " +
                    "IBleCommunicator.aidl and bleApi.version in gradle.properties, or undo the change."
            )
        }
        if (expected == null && requireFrozen.get()) {
            throw GradleException(
                "API_VERSION $version isn't frozen, and a release build needs it to be: run " +
                    "`./gradlew freezeBleApi` in ble_api/ and commit ${file.name}."
            )
        }
    }
}

/** Records the current API_VERSION's hash in frozen-api.properties. */
abstract class FreezeBleApi : DefaultTask() {
    @get:Input
    abstract val apiVersion: Property<Int>

    @get:Input
    abstract val apiHash: Property<String>

    @get:Internal
    abstract val frozenFile: RegularFileProperty

    @TaskAction
    fun freeze() {
        val file = frozenFile.get().asFile
        val frozen = Properties().apply { file.inputStream().use(::load) }
        val version = apiVersion.get()
        when (frozen.getProperty(version.toString())) {
            apiHash.get() -> logger.lifecycle("API_VERSION $version is already frozen.")
            null -> {
                file.appendText("$version=${apiHash.get()}\n")
                logger.lifecycle("Froze API_VERSION $version: ${apiHash.get()}")
            }
            else -> throw GradleException(
                "API_VERSION $version is already frozen with another interface; raise API_VERSION."
            )
        }
    }
}
