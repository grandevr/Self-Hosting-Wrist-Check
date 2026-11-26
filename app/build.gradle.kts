import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
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

android {
    namespace = "uk.debil.status"
    compileSdk = 36

    defaultConfig {
        applicationId = "uk.debil.status"
        minSdk = 30
        targetSdk = 36
        versionCode = 2
        versionName = "1.1.0"
        buildConfigField("String", "STATUS_URL", "\"${secret("STATUS_URL")}\"")
        buildConfigField("String", "STATUS_TOKEN", "\"${secret("STATUS_TOKEN")}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation(libs.wear.complications.data.source)
    implementation(libs.zxing.core)
}
