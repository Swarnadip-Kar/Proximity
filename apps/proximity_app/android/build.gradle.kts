allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// file_picker 11.0.3 deliberately skips `apply plugin:
// 'org.jetbrains.kotlin.android'` on AGP 9+ (its android/build.gradle
// only applies it when isAgp9OrAbove is false), assuming the consuming
// build provides Kotlin — flutter-plugin-loader 1.0.0 does not, so its
// Kotlin sources silently compile to an empty jar and the app's
// GeneratedPluginRegistrant fails with "cannot find symbol
// FilePickerPlugin". Apply it here (version from settings.gradle.kts,
// same as every other module); the JVM 17 forcing block below then
// covers its KotlinCompile tasks too.
subprojects {
    if (name == "file_picker") {
        apply(plugin = "org.jetbrains.kotlin.android")
    }
}

// Force JVM 17 for plugins shipping stale toolchains (tflite_flutter).
// Runs after all projects are evaluated so our values win.
gradle.projectsEvaluated {
    rootProject.subprojects {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>()
            .configureEach {
                compilerOptions {
                    jvmTarget.set(
                        org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
