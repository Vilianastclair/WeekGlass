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

val courseEngine = rootProject.file("../../../tooling/course_adapter_engine")
val courseDist = layout.buildDirectory.dir("course_parser").get().asFile
val buildCourseEngine by tasks.registering(Exec::class) {
    inputs.files(fileTree(courseEngine) {
        include("*.py", "*.zip", "src/*.kt", "LICENSE*", "licenses/**")
    })
    outputs.dir(courseDist)
    workingDir(courseEngine)
    commandLine(System.getenv("PYTHON") ?: "python", "build.py", "--dist", courseDist.absolutePath)
}
val engineJar = files(courseDist.resolve("engine.jar")).builtBy(buildCourseEngine)
val parserLibraries = files(
    courseDist.resolve("lib/jsoup-1.15.4.jar"),
    courseDist.resolve("lib/kotlin-csv-jvm-1.10.0.jar"),
).builtBy(buildCourseEngine)
tasks.named("preBuild") { dependsOn(buildCourseEngine) }

android {
    namespace = "com.viliana.weekglass.weekglass"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
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
            proguardFiles("course-adapter.pro")
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
    implementation(engineJar)
    implementation(parserLibraries)
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("org.jetbrains.kotlin:kotlin-stdlib:2.2.21")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.8.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // Already present in Flutter's dependency graph; pin the API we call directly.
    implementation("androidx.core:core:1.13.1")
    testImplementation("junit:junit:4.13.2")
}
