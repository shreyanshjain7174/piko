// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Piko",
    platforms: [.iOS("27.0"), .macOS(.v15)],
    products: [
        .library(name: "PikoKit", targets: ["PikoKit"]),
        .library(name: "PikoBridge", targets: ["PikoBridge"]),
        .library(name: "PikoAudio", targets: ["PikoAudio"]),
        .library(name: "PikoTranscribe", targets: ["PikoTranscribe"]),
        .library(name: "PikoBrain", targets: ["PikoBrain"]),
        .library(name: "PikoMemory", targets: ["PikoMemory"]),
        .library(name: "PikoMind", targets: ["PikoMind"]),
        .library(name: "PikoUI", targets: ["PikoUI"]),
        // Everything the keyboard extension is allowed to link. Keep this list short —
        // it is the build-time expression of the ~60 MB ceiling (see docs/CONSTRAINTS.md C4).
        .library(name: "PikoKeyboardKit", targets: ["PikoKit", "PikoBridge", "PikoUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .target(name: "PikoKit"),
        .target(name: "PikoBridge", dependencies: ["PikoKit"]),
        .target(name: "PikoAudio", dependencies: ["PikoKit"]),
        .target(name: "PikoTranscribe", dependencies: [
            "PikoKit",
            .product(name: "WhisperKit", package: "argmax-oss-swift", condition: .when(platforms: [.iOS])),
        ]),
        .target(name: "PikoMind", dependencies: ["PikoKit"]),
        .target(name: "PikoMemory", dependencies: ["PikoKit", "PikoMind"]),
        .target(name: "PikoBrain", dependencies: ["PikoKit", "PikoMemory"]),
        .target(name: "PikoUI", dependencies: ["PikoKit"], resources: [.process("Resources")]),
        .testTarget(name: "PikoKitTests", dependencies: ["PikoKit", "PikoBrain", "PikoMemory"]),
        .testTarget(name: "PikoMemoryTests", dependencies: ["PikoMemory", "PikoKit"]),
        .testTarget(name: "PikoMindTests", dependencies: ["PikoMind", "PikoMemory", "PikoKit"]),
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
                "PersonalMemoryView.swift",
                "ArmView.swift",
                "OnboardingView.swift",
                "HistoryView.swift",
                "PikoShortcuts.swift",
                "ArmSessionIntent.swift",
                "ReminderWriter.swift",
                "AssistantTools.swift",
                "PlanProbe.swift",
                "Voice.swift",
                "FiledView.swift",
                "LopLab.swift",
                "Pet",
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
