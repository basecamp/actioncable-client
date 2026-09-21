rootProject.name = "actioncable-client-kotlin"

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}

include(":actioncable-client")
project(":actioncable-client").projectDir = file("client")
include(":actioncable-client-testing")
project(":actioncable-client-testing").projectDir = file("testing")
