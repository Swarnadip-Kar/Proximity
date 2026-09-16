import java.util.Properties

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- Release signing (audit 2026-09-12 H4): never ship debug keys. ----
// Release credentials live in android/keystore.properties (gitignored —
// copy android/keystore.properties.template and fill it in). When the file
// is absent or incomplete, any release build (assembleRelease,
// bundleRelease, `flutter run --release`, `flutter build appbundle`)
// FAILS at configuration time with an actionable error instead of silently
// falling back to debug keys. Debug builds never read this file.
//
// Mint the release key ONCE on the release manager's machine (never commit
// the keystore, never email it — lose it and Play Store updates brick):
//   keytool -genkeypair -v -keystore ~/proximity-release.keystore \
//     -alias proximity-release -keyalg RSA -keysize 4096 -validity 10000
// Print the SHA-256 to register as certSha256 below and in Play Console:
//   keytool -list -v -keystore ~/proximity-release.keystore \
//     -alias proximity-release | grep SHA256
val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { stream -> keystoreProperties.load(stream) }
}
fun releaseCredential(name: String): String? =
    keystoreProperties.getProperty(name)?.trim()?.takeIf { it.isNotEmpty() }

val releaseStoreFile = releaseCredential("storeFile")
val releaseStorePassword = releaseCredential("storePassword")
val releaseKeyAlias = releaseCredential("keyAlias")
val releaseKeyPassword = releaseCredential("keyPassword")
// Pinned signing-cert SHA-256, verified at runtime by MainActivity (release
// builds fail closed on mismatch). Gradle property (-PreleaseCertSha256)
// wins so CI can inject it without writing files; otherwise certSha256 from
// keystore.properties; otherwise $RELEASE_CERT_SHA256. Compared canonical:
// colons/whitespace stripped, uppercase.
val releaseCertSha256: String = (
    project.findProperty("releaseCertSha256")?.toString()
        ?: keystoreProperties.getProperty("certSha256")
        ?: System.getenv("RELEASE_CERT_SHA256")
        ?: ""
    ).replace(":", "").replace("\\s".toRegex(), "").uppercase()
val missingReleaseKeys = listOf(
    "storeFile" to releaseStoreFile,
    "storePassword" to releaseStorePassword,
    "keyAlias" to releaseKeyAlias,
    "keyPassword" to releaseKeyPassword,
).filter { it.second == null }.map { it.first }
val hasReleaseSigning = missingReleaseKeys.isEmpty() &&
    keystorePropertiesFile.exists() &&
    rootProject.file(releaseStoreFile!!).isFile

// Loud fail-closed gate: evaluated for every invocation, but only throws
// when a release task was actually requested, so debug flows (`flutter run`,
// `flutter build apk --debug`, IDE sync, CI) are never blocked by release
// credential hygiene.
val wantsReleaseBuild =
    gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
if (wantsReleaseBuild) {
    if (!keystorePropertiesFile.exists()) {
        throw GradleException(
            "Proximity release signing: android/keystore.properties is missing — " +
                "refusing to sign a release with debug keys (audit 2026-09-12 H4). " +
                "Copy android/keystore.properties.template to android/keystore.properties " +
                "(gitignored, never commit it), mint the key with the keytool command at " +
                "the top of app/build.gradle.kts, and fill in storeFile/storePassword/" +
                "keyAlias/keyPassword/certSha256. Debug builds are unaffected."
        )
    }
    if (missingReleaseKeys.isNotEmpty()) {
        throw GradleException(
            "Proximity release signing: android/keystore.properties is missing " +
                "required entries: ${missingReleaseKeys.joinToString()}. " +
                "See android/keystore.properties.template. Refusing to sign."
        )
    }
    if (!rootProject.file(releaseStoreFile!!).isFile) {
        throw GradleException(
            "Proximity release signing: storeFile '${releaseStoreFile}' does not exist " +
                "(resolved relative to android/). Fix the path in android/keystore.properties. " +
                "Refusing to sign."
        )
    }
    if (!releaseCertSha256.matches(Regex("[0-9A-F]{64}"))) {
        throw GradleException(
            "Proximity release signing: pinned cert SHA-256 is missing or malformed " +
                "(got '${releaseCertSha256.ifEmpty { "<empty>" }}', want 64 hex chars). " +
                "Pass -PreleaseCertSha256=<sha256>, set certSha256 in " +
                "android/keystore.properties, or export RELEASE_CERT_SHA256. Print it with: " +
                "keytool -list -v -keystore <storeFile> -alias <keyAlias> | grep SHA256. " +
                "An unpinned release build would make the MainActivity self-check " +
                "theater, so the build stops here."
        )
    }
}

android {
    namespace = "org.iitbhilai.proximity"
    // Flutter default (36): permission_handler is pinned to 12.x, whose
    // android impl needs only API 34 — nothing in the tree needs 37, and
    // Google has not published platforms;android-37 (stable repo tops out
    // at 36), so a hardcoded 37 compiles nowhere. See pubspec pin note.
    compileSdk = flutter.compileSdkVersion
    // NDK audit 2026-09-12 H4: this repo compiles zero native sources (no
    // jni/, no CMakeLists.txt, no .c/.cpp under android/). Native .so files
    // arrive prebuilt inside the tflite_flutter AAR (TensorFlow Lite
    // runtime), which needs no externalNativeBuild/abiFilters from us. The
    // flutter.ndkVersion pin below satisfies the AGP toolchain requirement.
    // Do NOT add speculative NDK config here.
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.iitbhilai.proximity"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            // Sentinel: debug builds skip the MainActivity self-check, so
            // this value is never read outside release.
            buildConfigField("String", "RELEASE_CERT_SHA256", "\"\"")
        }
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
            // If hasReleaseSigning is false the gate above has already thrown
            // for any release invocation, so reaching here unsigned is
            // impossible via a real release task.
            buildConfigField("String", "RELEASE_CERT_SHA256", "\"$releaseCertSha256\"")
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
