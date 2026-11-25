import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
}

// URL and bearer token come from secrets.properties in the project root (not committed).
val secrets = Properties().apply {
    val f = rootProject.file("secrets.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun secret(name: String): String {
    val value = secrets.getProperty(name)?.trim().orEmpty()
    if (value.isEmpty()) {
        throw GradleException(
            "$name is missing. Copy secrets.properties.example to secrets.properties " +
                "in the project root and fill in STATUS_URL and STATUS_TOKEN."
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
        versionCode = 1
        versionName = "1.0.0"
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
    implementation(libs.wear.tiles)
    implementation(libs.wear.protolayout)
    implementation(libs.concurrent.futures)
}
