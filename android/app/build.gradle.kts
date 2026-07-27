plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.mobilecode.mobilecode"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.mobilecode.mobilecode"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Android refuses to update an installed app when the signing key
    // changes, and Gradle generates a fresh ~/.android/debug.keystore whenever
    // one is absent. CI runners start clean every time, so debug-signed builds
    // get a different key each run and can only be installed by uninstalling
    // first — which also destroys the user's hosts, pins, and stored keys.
    //
    // Supplying a keystore through the environment keeps the signature stable
    // across runs, so a new build installs over the old one as an update.
    // takeIf: an unset GitHub Actions secret expands to an empty string rather
    // than being absent, and "" is not a keystore path.
    val releaseKeystore =
        System.getenv("MOBILECODE_KEYSTORE_PATH")?.takeIf { it.isNotBlank() }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("MOBILECODE_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("MOBILECODE_KEY_ALIAS") ?: "mobilecode"
                keyPassword = System.getenv("MOBILECODE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Falls back to debug signing so a plain `flutter run --release`
            // still works with no keystore configured.
            signingConfig = if (releaseKeystore != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
