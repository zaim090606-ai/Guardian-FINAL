plugins {
    // Standard Flutter plugins for Android
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    id("com.google.gms.google-services") version "4.4.1" apply false
}

// Global repositories ensuring Jitpack is available for background_sms and others
allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

// Build directory configuration
val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Safely assign namespace for legacy packages (like background_sms)
// Wrapped in a try-catch to prevent build failures during Gradle graph resolution
subprojects {
    afterEvaluate {
        if (project.plugins.hasPlugin("com.android.library")) {
            val androidExt = project.extensions.findByName("android")
            if (androidExt != null) {
                try {
                    val namespaceGetter = androidExt.javaClass.getMethod("getNamespace")
                    val currentNamespace = namespaceGetter.invoke(androidExt)
                    if (currentNamespace == null) {
                        val namespaceSetter = androidExt.javaClass.getMethod("setNamespace", String::class.java)
                        namespaceSetter.invoke(androidExt, "com.background_sms.plugin")
                    }
                } catch (e: Exception) {
                    // Silently catch exceptions so it doesn't crash the build graph
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}