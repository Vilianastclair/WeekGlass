import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingIdentity = Properties().apply {
    rootProject.file("signing.properties").inputStream().use { load(it) }
}
val unsignedRelease = providers.gradleProperty("weekglassUnsignedRelease").orNull == "true"

android {
    namespace = "com.viliana.weekglass.weekglass"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.viliana.weekglass"
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "LEGACY_CERTIFICATE_SHA256", "\"${signingIdentity.getProperty("legacyCertificateSha256")}\"")
        buildConfigField("String", "PRODUCTION_CERTIFICATE_SHA256", "\"${signingIdentity.getProperty("productionCertificateSha256")}\"")
        buildConfigField("int", "SIGNER_ROTATION_MIN_SDK", signingIdentity.getProperty("rotationMinimumSdk"))
    }

    buildFeatures { buildConfig = true }

    // ABI filters merge across defaultConfig and build type. Scope Flutter's
    // defaults here so debug/profile retain their existing architecture support.
    val developmentAbis = defaultConfig.ndk.abiFilters.toSet()
    defaultConfig.ndk.abiFilters.clear()
    buildTypes {
        configureEach {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(if (name == "release") setOf("arm64-v8a") else developmentAbis)
            }
        }
        release {
            // Local builds still use the development key. The publishing build leaves this
            // APK unsigned so apksigner can apply the SDK-specific certificate lineage.
            signingConfig = if (unsignedRelease) null else signingConfigs.getByName("debug")
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
    // Already present in Flutter's dependency graph; pin the API we call directly.
    implementation("androidx.core:core:1.13.1")
    testImplementation("junit:junit:4.13.2")
}
