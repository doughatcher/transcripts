# Transcripts — pocket recorder for iOS.
# `brew install xcodegen just` to bootstrap.

export DEVELOPER_DIR := "/Applications/Xcode.app/Contents/Developer"

default: build

# Regenerate Transcripts.xcodeproj from project.yml (the xcodeproj is not
# checked in — the spec is the source of truth).
project:
    xcodegen generate --project ios --project-root .

# Build for the iOS Simulator (no signing required).
build: project
    xcodebuild build -project ios/Transcripts.xcodeproj -scheme Transcripts \
      -destination 'generic/platform=iOS Simulator' \
      CODE_SIGNING_ALLOWED=NO | tail -5

# Open in Xcode (for device runs, signing, archives).
open: project
    open ios/Transcripts.xcodeproj
