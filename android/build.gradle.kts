import com.android.build.gradle.LibraryExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// 所有原生模块产物统一到 Flutter 根目录的 build，便于清理和定位。
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
    if (name == "coinbase_wallet_sdk") {
        // shortcut: Coinbase 依赖固定旧 SDK 且引用缺失混淆文件；依赖修复后移除此兼容覆盖。
        afterEvaluate {
            extensions.configure<LibraryExtension> {
                compileSdk = 36
                defaultConfig {
                    consumerProguardFiles.clear()
                }
                buildTypes.configureEach {
                    proguardFiles.clear()
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
