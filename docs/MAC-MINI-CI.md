# Mac mini builds

Build/test, TestFlight, Mac App Store, and Developer ID release jobs require
`self-hosted`, `macOS`, `ARM64`, `transcripts-macos`, and
`transcripts-mini-validation`. The registered runner is `mac-mini-transcripts`
on `mac-mini.local`. There is no hosted Mac fallback. Fork PRs are skipped on
this personal machine; review and move trusted changes into a repository branch.
Non-build Linux metadata and site jobs retain their existing runner selection.

The Mini needs Xcode (including Metal), xcodegen, and GitHub CLI on its runner
PATH. Release jobs install Node 24 through actions/setup-node. The service runs
as doug, independently of the Pro. Its LaunchAgent starts after user login;
FileVault preboot unlock remains a separate requirement after a cold restart.

Signing jobs save the existing keychain search list, use a temporary signing
keychain and API-key directory, then restore the search list and remove signing
material in an always-run cleanup step. No API key is installed in the Mini's
permanent .appstoreconnect directory. If the runner is forcibly killed during a
signing job, run `RUNNER_TEMP=<that job's temp directory> python3
scripts/ci-signing.py cleanup` before another release. Do not remove the saved
state file before cleanup.

Validate build changes with the build workflow; do not trigger TestFlight or
release workflows merely to test runner routing, because they publish builds.
