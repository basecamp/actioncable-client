plugins {
    base
    alias(libs.plugins.kotlin.multiplatform) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}

allprojects {
    group = "com.basecamp"
    version = "2.0.0"
}

// Pin javac's source encoding for every module, the way basecamp-sdk/kotlin does.
// No module has Java sources today, so this is prophylactic: it is the first
// `.java` file that would otherwise read UTF-8 prose as US-ASCII under a C
// locale, which is exactly the moment nobody would think to look.
subprojects {
    tasks.withType<JavaCompile>().configureEach {
        options.encoding = "UTF-8"
    }
}

// ktlint runs from its CLI jar rather than a Gradle plugin, so the build
// carries no plugin of its own to keep current. `.editorconfig` points it at
// the IntelliJ style, which is what `kotlin.code.style=official` means
// everywhere else here.
val ktlint =
    configurations.create("ktlint") {
        // ktlint-cli publishes a plain runtime classpath and a shadowed fat jar,
        // and nothing else tells them apart, so the choice has to be stated. The
        // fat jar is the one that runs: the plain one leaves out the command-line
        // parser the entry point needs.
        attributes {
            attribute(Bundling.BUNDLING_ATTRIBUTE, objects.named(Bundling::class.java, Bundling.SHADOWED))
        }
    }

dependencies {
    ktlint(libs.ktlint.cli)
}

val sources = listOf("client/src/**/*.kt", "testing/src/**/*.kt", "*.gradle.kts")

val lint =
    tasks.register<JavaExec>("lint") {
        group = "verification"
        description = "Check formatting with ktlint"
        classpath = ktlint
        mainClass.set("com.pinterest.ktlint.Main")
        args = sources
        jvmArgs("--add-opens=java.base/java.lang=ALL-UNNAMED")
    }

tasks.register<JavaExec>("fmt") {
    group = "formatting"
    description = "Rewrite sources in the house format with ktlint"
    classpath = ktlint
    mainClass.set("com.pinterest.ktlint.Main")
    args = listOf("--format") + sources
    jvmArgs("--add-opens=java.base/java.lang=ALL-UNNAMED")
}

// `check` and `build` reach every subproject by name on their own. `test` does
// not: the multiplatform plugin names its test task `allTests`. Both names are
// declared here so the root Makefile has one target name that works.
tasks.register("test") {
    group = "verification"
    description = "Run every test in every module"
    dependsOn(subprojects.map { "${it.path}:allTests" })
}

tasks.check {
    dependsOn(lint)
}

tasks.wrapper {
    retries.set(3)
    retryBackOffMs.set(500)
}
