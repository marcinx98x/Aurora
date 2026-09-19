import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

fun resolveCastReceiverAppId(): String {
    System.getenv("CAST_RECEIVER_APP_ID")?.trim()?.takeIf { it.isNotEmpty() }?.let {
        return it
    }
    val localProps = Properties()
    val localFile = rootProject.file("local.properties")
    if (localFile.exists()) {
        localFile.inputStream().use { localProps.load(it) }
        localProps.getProperty("cast.receiver.app.id")?.trim()?.takeIf { it.isNotEmpty() }?.let {
            return it
        }
    }
    // Flutter project .env (same file as --dart-define-from-file=.env)
    val envFile = rootProject.file("../.env")
    if (envFile.exists()) {
        envFile.readLines().forEach { line ->
            val trimmed = line.trim()
            if (trimmed.startsWith("#") || !trimmed.startsWith("CAST_RECEIVER_APP_ID=")) return@forEach
            val value = trimmed.substringAfter("=").trim().trim('"')
            if (value.isNotEmpty()) return value
        }
    }
    // Fallback keeps builds working until Cast Console App ID is set.
    // CC1AD845 = Default Media Receiver (no custom TV UI).
    return "CC1AD845"
}

android {
    namespace = "com.example.aurora_music"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        // Required by flutter_local_notifications (uses java.time backport).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.aurora.music"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Flutter 3.27 defaults to 21, while Firebase Auth requires 23.
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField(
            "String",
            "CAST_RECEIVER_APP_ID",
            "\"${resolveCastReceiverAppId()}\"",
        )
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("com.google.android.gms:play-services-cast-framework:21.5.0")
    implementation("androidx.mediarouter:mediarouter:1.7.0")
}

flutter {
    source = "../.."
}
