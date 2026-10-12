// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HyperBrowser",
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .library(name: "BrowserStorage", targets: ["BrowserStorage"]),
        .library(name: "BrowserUI", targets: ["BrowserUI"]),
        .library(name: "BrowserSettingsUI", targets: ["BrowserSettingsUI"]),
        .library(name: "DownloadKit", targets: ["DownloadKit"]),
        .library(name: "DownloadProtocol", targets: ["DownloadProtocol"]),
        .executable(name: "OreeDownloader", targets: ["OreeDownloader"]),
        .library(name: "OreeAIProtocol", targets: ["OreeAIProtocol"]),
        .library(name: "OreeAIEngine", targets: ["OreeAIEngine"]),
        .library(name: "OreeAIClient", targets: ["OreeAIClient"]),
        .executable(name: "OreeAI", targets: ["OreeAI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "6.0.0")),
    ],
    targets: [
        // Rust adblock-rust bridge: prebuilt static library wrapped as an
        // xcframework (see Rust/build_bridge.sh), plus its UniFFI-generated Swift.
        .binaryTarget(
            name: "adblock_bridgeFFI",
            path: "Frameworks/AdblockBridgeFFI.xcframework"
        ),
        .target(
            name: "AdblockBridge",
            dependencies: ["adblock_bridgeFFI"],
            // Generated code, not ours to make Swift-6-strict-clean.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Pure logic: tab ordering/state, session persistence helpers,
        // settings, browser-data import, content blocking, logging. No AppKit.
        .target(
            name: "BrowserCore",
            dependencies: ["AdblockBridge"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BrowserCoreTests",
            dependencies: ["BrowserCore", "AdblockBridge"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // GRDB-backed storage: history, bookmarks, FTS5 search, frecency.
        .target(
            name: "BrowserStorage",
            dependencies: ["BrowserCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BrowserStorageTests",
            dependencies: ["BrowserStorage"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // AppKit: windows, tabs, address bar, web view hosting. Depends on
        // BrowserSettingsUI only to host the settings window via
        // NSHostingController — it doesn't otherwise touch SwiftUI.
        .target(
            name: "BrowserUI",
            dependencies: ["BrowserCore", "BrowserStorage", "BrowserSettingsUI", "DownloadKit", "DownloadProtocol", "OreeAIClient", "OreeAIEngine", "OreeObjC"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Un seul fichier Objective-C : attraper les exceptions de WebKit, que Swift ne sait pas attraper (voir OreeObjC.h).
        .target(name: "OreeObjC"),

        // Côté navigateur du service IA local : client XPC et décisions d'état (testables avec un faux service).
        .target(
            name: "OreeAIClient",
            dependencies: ["OreeAIProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OreeAIClientTests",
            dependencies: ["OreeAIClient", "OreeAIProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // SwiftUI: settings screens only, per project convention.
        .target(
            name: "BrowserSettingsUI",
            dependencies: ["BrowserCore", "BrowserStorage"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Download engine: segmented multi-connection downloads written straight to disk.
        // Pure Swift (no AppKit, no XPC) so it is testable on its own.
        .target(
            name: "DownloadKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DownloadKitTests",
            dependencies: ["DownloadKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // XPC protocol + client/service wrappers shared by the app and the downloader process.
        .target(
            name: "DownloadProtocol",
            dependencies: ["DownloadKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DownloadProtocolTests",
            dependencies: ["DownloadProtocol", "DownloadKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The separate process that owns the downloads (a launchd agent, so they outlive the browser).
        .executableTarget(
            name: "OreeDownloader",
            dependencies: ["DownloadKit", "DownloadProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Protocole XPC et événements du service IA local. Sans dépendance : partagé avec la session navigateur.
        .target(
            name: "OreeAIProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OreeAIProtocolTests",
            dependencies: ["OreeAIProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // llama.cpp précompilé (Metal inclus) : ce Mac n'a pas de compilateur Metal, on ne le compile jamais ici.
        // Version b11556 : connaît l'architecture qwen35. Somme = SHA-256 du zip (vérifiée aussi avec `swift package compute-checksum`).
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11556/llama-b11556-xcframework.zip",
            checksum: "d7b4cf441bd8958c7ffbb5a6ef82a3302cfd8a5d330f2ed081ecf69b6e2a0f41"
        ),
        // Logique du service IA (états chaud/tiède/froid, vérification du modèle, hôte XPC). Sans llama.cpp : testable avec un faux moteur.
        .target(
            name: "OreeAIEngine",
            dependencies: ["OreeAIProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OreeAIEngineTests",
            dependencies: ["OreeAIEngine", "OreeAIProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Le processus du service (agent launchd à la demande) : OreeAIEngine + llama.cpp.
        .executableTarget(
            name: "OreeAI",
            dependencies: ["OreeAIEngine", "OreeAIProtocol", "llama"],
            path: "Sources/OreeAIService",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .executableTarget(
            name: "HyperBrowserApp",
            dependencies: ["BrowserCore", "BrowserStorage", "BrowserUI", "BrowserSettingsUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
