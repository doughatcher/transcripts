// The macOS menu-bar app lands here: capture (mic + system audio via
// ScreenCaptureKit), call detection, the pipeline, the menu bar, and settings.
// Placeholder entry point so the package builds while the port proceeds.
import TranscriptsCore
import TranscriptsEngine

let config = AppConfig.default
print("Transcripts — macOS port in progress. Vault: \(config.destinations.knowledgeRoot)")
