plugins {
    alias(libs.plugins.kotlin.multiplatform)
    `maven-publish`
}

kotlin {
    jvm()

    sourceSets {
        commonMain.dependencies {
            api(project(":actioncable-client"))
            implementation(libs.kotlinx.coroutines.core)
        }
    }
}

publishing {
    repositories {
        maven {
            name = "GitHubPackages"
            url = uri("https://maven.pkg.github.com/basecamp/actioncable-client")
            credentials {
                username = System.getenv("GITHUB_USER") ?: "x-access-token"
                password = System.getenv("GITHUB_ACCESS_TOKEN") ?: ""
            }
        }
    }
}
