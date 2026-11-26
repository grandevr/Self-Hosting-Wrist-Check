import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// Optional build-time defaults for the URL and bearer token, from secrets.properties in the
// project root (not committed). Without the file the app builds fine and is set up on the watch
// instead (browser or on-watch entry). If the file exists, both values must be filled in.
val secrets = Properties().apply {
    val f = rootProject.file("secrets.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasSecrets = rootProject.file("secrets.properties").exists()
fun secret(name: String): String {
    if (!hasSecrets) return ""
    val value = secrets.getProperty(name)?.trim().orEmpty()
    if (value.isEmpty()) {
        throw GradleException(
            "$name is missing in secrets.properties. Fill in STATUS_URL and STATUS_TOKEN, " +
                "or delete the file to set the app up on the watch instead."
        )
    }
    return value.replace("\\", "\\\\").replace("\"", "\\\"")
}

// Release signing key, from keystore.properties in the project root (not committed). Keep the
// same keystore for every build so new APKs install over old ones with `adb install -r`.
// Without the file, release builds are signed with this machine's debug key instead.
val keystoreFile = rootProject.file("keystore.properties")
val keystore = Properties().apply {
    if (keystoreFile.exists()) keystoreFile.inputStream().use { load(it) }
}
fun keystoreValue(name: String): String {
    val value = keystore.getProperty(name)?.trim().orEmpty()
    if (value.isEmpty()) {
        throw GradleException(
            "$name is missing in keystore.properties. Fill in storeFile, storePassword, keyAlias " +
                "and keyPassword (see keystore.properties.example), or delete the file to sign " +
                "with the debug key."
        )
    }
    return value
}

android {
    namespace = "uk.debil.status"
    compileSdk = 36

    defaultConfig {
        applicationId = "uk.debil.status"
        minSdk = 30
        targetSdk = 36
        versionCode = 8
        versionName = "1.3.3"
        buildConfigField("String", "STATUS_URL", "\"${secret("STATUS_URL")}\"")
        buildConfigField("String", "STATUS_TOKEN", "\"${secret("STATUS_TOKEN")}\"")
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (keystoreFile.exists()) {
            create("release") {
                storeFile = rootProject.file(keystoreValue("storeFile"))
                storePassword = keystoreValue("storePassword")
                keyAlias = keystoreValue("keyAlias")
                keyPassword = keystoreValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // R8 strips the unused parts of Compose and the other libraries, and drops
            // resources nothing refers to. Keep rules: proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation(libs.wear.complications.data.source)
    implementation(libs.zxing.core)
    implementation(libs.activity.compose)
    implementation(libs.wear.compose.material3)
    implementation(libs.wear.compose.foundation)
}
