// swift-tools-version: 5.9

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "LectureBuddy",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "LectureBuddy",
            targets: ["AppModule"],
            bundleIdentifier: "com.example.lecturebuddy",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .palette),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .microphone(purposeString: "需要用麦克风录制课堂声音，生成实时字幕、转写和笔记。录音只保存在这台 iPad 上。"),
                .speechRecognition(purposeString: "需要用语音识别把老师说的话转成文字，才能生成双语字幕和课堂笔记。")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources"
        )
    ]
)