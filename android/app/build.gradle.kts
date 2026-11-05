plugins {
    id("com.android.application")
    // Flutter 插件放在 Android 插件之后，使其能接管 Flutter 的编译与资源打包。
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.krquant.hyperliquid_testnet_terminal"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Android 应用标识；已有安装、深链和签名配置都依赖它，不随页面改名。
        applicationId = "com.krquant.hyperliquid_testnet_terminal"
        // Sentry 10 原生插件要求 Android 8.0 / API 26，目标版本仍沿用 Flutter。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // 从 pubspec.yaml 的版本和构建号读取，避免两端分别维护版本。
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // shortcut: release 暂用 debug 签名，仅供本地验证；发布前必须配置正式签名。
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
