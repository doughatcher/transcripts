// swift-tools-version:5.9
import PackageDescription

// The shared libraries. Both apps are targets in the generated Xcode project
// (`project.yml` → xcodegen), because SwiftPM cannot produce an .app bundle and
// having exactly one project avoids xcodebuild resolving the wrong one.
//
// The split that matters is Core vs Engine:
//
//   TranscriptsCore   — zero external dependencies. Pipeline, config, routing,
//                       models, audio maths, speaker profiles. Both platforms
//                       link it, which is what keeps the iOS app free of any
//                       third-party code at all.
//   TranscriptsEngine — FluidAudio (diarization) and MLX (local LLM). macOS
//                       only. iOS deliberately does not link this: MLX alone
//                       would drag a ~1.8 GB model download onto a phone, and
//                       Meta's Llama licence along with it.
let package = Package(
    name: "Transcripts",
    platforms: [
        // macOS 14 for SettingsLink and the modern MenuBarExtra APIs;
        // ScreenCaptureKit audio capture also matured here.
        .macOS(.v14),
        // Matches the iOS app's floor, so Core compiles for both unmodified.
        .iOS(.v17),
    ],
    products: [
        .library(name: "TranscriptsCore", targets: ["TranscriptsCore"]),
        .library(name: "TranscriptsEngine", targets: ["TranscriptsEngine"]),
    ],
    dependencies: [
        // On-device speaker diarization (Core ML) for the "who said what" pass
        // over the system-audio side of a call.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
        // In-process LLM inference (Apple MLX) — the summarization tier used
        // when Apple Intelligence is unavailable. No daemon, nothing to install.
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "2.29.1"),
        // Constraint only (no product consumed). Jinja was capped at 2.3.x
        // while swift-transformers 1.0.x failed to compile against 2.4.0's
        // reworked value types; 2.5.1 builds clean (both CI builds, Mac app
        // included), so the cap became a floor. Package.resolved pins the rest.
        .package(url: "https://github.com/huggingface/swift-jinja.git", from: "2.5.1"),
    ],
    targets: [
        .target(name: "TranscriptsCore"),
        .target(
            name: "TranscriptsEngine",
            dependencies: [
                "TranscriptsCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
            ]
        ),
        .testTarget(name: "TranscriptsCoreTests", dependencies: ["TranscriptsCore"]),
        .testTarget(name: "TranscriptsEngineTests", dependencies: ["TranscriptsEngine"]),
    ]
)
