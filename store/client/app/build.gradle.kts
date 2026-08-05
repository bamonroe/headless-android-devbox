plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.bam.store"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.bam.store"
        minSdk = 29
        targetSdk = 35
        versionCode = 3
        versionName = "0.1.2"
    }

    signingConfigs {
        // Pin the debug signing key when BAM_STORE_DEBUG_KEYSTORE points at one, so
        // containerized builds (which otherwise mint a random debug key each time)
        // produce a stable signature and `adb install -r` upgrades in place.
        getByName("debug") {
            val ks = System.getenv("BAM_STORE_DEBUG_KEYSTORE")
            if (ks != null && file(ks).exists()) {
                storeFile = file(ks)
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // HTTP transport to the repository (fetch index.json, download APKs).
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // Load remote app icons into Compose.
    implementation("io.coil-kt:coil-compose:2.7.0")
}
