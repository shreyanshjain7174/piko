// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Piko",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "PikoKit", targets: ["PikoKit"]),
        .library(name: "PikoBridge", targets: ["PikoBridge"]),
        .library(name: "PikoAudio", targets: ["PikoAudio"]),
        .library(name: "PikoTranscribe", targets: ["PikoTranscribe"]),
        .library(name: "PikoBrain", targets: ["PikoBrain"]),
        .library(name: "PikoMemory", targets: ["PikoMemory"]),
        .library(name: "PikoUI", targets: ["PikoUI"]),
        // Everything the keyboard extension is allowed to link. Keep this list short —
        // it is the build-time expression of the ~60 MB ceiling (see docs/CONSTRAINTS.md C4).
        .library(name: "PikoKeyboardKit", targets: ["PikoKit", "PikoBridge", "PikoUI"]),
    ],
    targets: [
        .target(name: "PikoKit"),
        .target(name: "PikoBridge", dependencies: ["PikoKit"]),
        .target(name: "PikoAudio", dependencies: ["PikoKit"]),
        .target(name: "PikoTranscribe", dependencies: ["PikoKit"]),
        .target(name: "PikoMemory", dependencies: ["PikoKit"]),
        .target(name: "PikoBrain", dependencies: ["PikoKit", "PikoMemory"]),
        .target(name: "PikoUI", dependencies: ["PikoKit"], resources: [.process("Resources")]),
        .testTarget(name: "PikoKitTests", dependencies: ["PikoKit", "PikoBrain", "PikoMemory"]),
        .testTarget(name: "PikoMemoryTests", dependencies: ["PikoMemory", "PikoKit"]),
        .testTarget(name: "PikoUITests", dependencies: ["PikoUI", "PikoKit"]),
        .testTarget(name: "PikoBridgeTests", dependencies: ["PikoBridge", "PikoKit"]),
        .testTarget(name: "PikoAudioTests", dependencies: ["PikoAudio", "PikoKit"]),
        .testTarget(name: "PikoTranscribeTests", dependencies: ["PikoTranscribe", "PikoKit", "PikoAudio", "PikoCaptureCore", "PikoBrain", "PikoMemory"]),
        // CaptureCoordinator lives in App/Piko; expose it to PikoTranscribeTests
        // the same way PikoKeyboardCore exposes insertion without the UIKit app shell.
        .target(
            name: "PikoCaptureCore",
            dependencies: ["PikoKit", "PikoAudio", "PikoTranscribe", "PikoBridge", "PikoBrain"],
            path: "App/Piko",
            exclude: [
                "AppComposition.swift",
                "PikoApp.swift",
                "RootView.swift",
                "ArmView.swift",
                "OnboardingView.swift",
                "HistoryView.swift",
                "MemoryView.swift",
                "PikoSpeaker.swift",
                "MemoryMaintenance.swift",
                "PikoShortcuts.swift",
                "ArmSessionIntent.swift",
                "Info.plist",
                "Piko.entitlements",
            ]
        ),
        // Insertion algorithm only — so PikoKeyboardTests can exercise App/PikoKeyboard
        // TextInsertionController without compiling the UIKit keyboard shell on macOS.
        .target(
            name: "PikoKeyboardCore",
            dependencies: ["PikoKit"],
            path: "App/PikoKeyboard",
            exclude: [
                "KeyboardViewController.swift",
                "KeyboardView.swift",
                "MicButton.swift",
                "Info.plist",
                "PikoKeyboard.entitlements",
            ]
        ),
        .testTarget(name: "PikoKeyboardTests", dependencies: ["PikoKit", "PikoKeyboardCore"]),
        .testTarget(name: "PikoBrainTests", dependencies: ["PikoBrain", "PikoKit"]),
    ]
)
