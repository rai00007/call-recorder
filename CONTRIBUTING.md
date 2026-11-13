# Contributing

Thanks for helping! The app lives in `CallRecorder/` (SwiftUI + AppKit); keep it dependency-free and simple. Non-UI logic goes in files that don't import SwiftUI so `swift test` can cover it (`App/`, `Views/`, `MenuBar/` are excluded from the test package).

1. Fork and clone, then `./build.sh && open CallRecorder.app` (macOS 26+, Xcode command line tools).
2. Run `swift test`. Make focused changes; describe what you tested (record a short call, check the transcript and minutes in the app).
3. Never commit recordings, transcripts or personal data (`recordings/` is git-ignored).
4. Open a PR describing the change and why.

Bug reports: include your macOS version, Mac type (Apple Silicon/Intel), and the alert text or output.
