import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The phone and watch APKs must be signed with the same key for the Wearable
// Data Layer to connect them. Provide android/key.properties (or the
// TRACKWATCH_KEYSTORE* environment variables in CI); otherwise the local debug
// key is used, which is fine as long as both APKs are built on the same machine.
val signing = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
    System.getenv("TRACKWATCH_KEYSTORE")?.let {
        setProperty("storeFile", it)
        setProperty("storePassword", System.getenv("TRACKWATCH_KEYSTORE_PASSWORD"))
        setProperty("keyAlias", System.getenv("TRACKWATCH_KEY_ALIAS"))
        setProperty("keyPassword", System.getenv("TRACKWATCH_KEY_PASSWORD"))
    }
}
val hasSharedKey = signing.getProperty("storeFile") != null

android {
    namespace = "su.iho.trackwatch"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Phone and watch apps must share the application id for the Data Layer.
        applicationId = "su.iho.trackwatch"
        minSdk = 31
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "device"
    productFlavors {
        create("phone") {
            dimension = "device"
        }
        create("wear") {
            dimension = "device"
            minSdk = 30
        }
    }

    signingConfigs {
        if (hasSharedKey) {
            create("shared") {
                storeFile = file(signing.getProperty("storeFile"))
                storePassword = signing.getProperty("storePassword")
                keyAlias = signing.getProperty("keyAlias")
                keyPassword = signing.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        val key = if (hasSharedKey) signingConfigs.getByName("shared") else signingConfigs.getByName("debug")
        getByName("debug") {
            signingConfig = key
        }
        getByName("release") {
            signingConfig = key
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
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
    implementation("com.google.android.gms:play-services-wearable:18.2.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.10.2")
    implementation("androidx.core:core-ktx:1.15.0")

    "phoneImplementation"("androidx.work:work-runtime-ktx:2.10.0")
    "phoneImplementation"("com.squareup.okhttp3:okhttp:4.12.0")
    "phoneImplementation"("com.google.android.gms:play-services-auth-blockstore:16.4.0")

    "wearImplementation"("androidx.wear.tiles:tiles:1.4.1")
    "wearImplementation"("androidx.wear.protolayout:protolayout:1.2.1")
    "wearImplementation"("androidx.wear.protolayout:protolayout-expression:1.2.1")
    "wearImplementation"("androidx.wear.protolayout:protolayout-material:1.2.1")
    "wearImplementation"("androidx.wear.watchface:watchface-complications-data-source-ktx:1.2.1")
    "wearImplementation"("androidx.wear:wear-ongoing:1.0.0")
    "wearImplementation"("androidx.wear:wear-input:1.1.0")
    "wearImplementation"("androidx.wear:wear:1.3.0")
    "wearImplementation"("androidx.wear:wear-remote-interactions:1.1.0")
    "wearImplementation"("com.google.guava:guava:33.3.1-android")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
