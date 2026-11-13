# Call Recorder — open-source meeting recorder, transcriber & AI meeting minutes for macOS

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey)
![Swift](https://img.shields.io/badge/swift-SwiftUI%20%2B%20AppKit-orange)

A **private, local-first** native macOS app (main window + menu-bar icon) that records any call or meeting
(Zoom, Google Meet, Microsoft Teams, FaceTime, Slack huddles, …), transcribes it on-device,
and writes **meeting minutes** — summary, discussion points, decisions and action items —
with a local open-source LLM. No bot joins your call, no account, no API key, nothing is uploaded.

An open-source, self-hosted alternative to cloud note-takers like Otter.ai, Fireflies, Fathom and Granola
for people who want their meeting audio to stay on their own machine.

<p align="center">
  <video src="docs/demo.mp4" controls muted width="720">
    Your viewer can't play the video — <a href="docs/demo.mp4">watch the demo (mp4)</a>.
  </video>
</p>

## Features

- **Records any app** — captures system audio (other participants) + your microphone via ScreenCaptureKit, mixed into one `.m4a`. It records the Mac, it doesn't join the meeting.
- **On-device transcription** — Apple's built-in speech models (`SpeechAnalyzer`, with automatic fallback to `DictationTranscriber`). Timestamps included.
- **"Me" vs "Others" speaker labels** — your mic and the system audio are transcribed separately and interleaved, so you can tell what you said from what everyone else said.
- **Meeting minutes written by a local LLM** — via [Ollama](https://ollama.com) (default `qwen2.5:3b`): summary, key points, decisions, action items with owners and due dates. Long meetings are chunked and merged.
- **Hallucination guards** — the model is told to say "not stated" instead of guessing, and transcripts too short to summarize are skipped.
- **Native library** — browse, search (title + transcript), rename and delete recordings; play audio with seek and 0.5–2× speed; tabs for Summary, Transcript, Audio and Actions.
- **Editable action items** — extracted from the minutes (owner/due date only when stated), editable, exportable. Transcript edits are saved separately from the original.
- **Retry independently** — re-run transcription or summarization without recording again; Ollama is optional.
- **Safe by default** — raw mic/system tracks are never deleted automatically; per-recording and bulk cleanup is up to you (Manage storage). Deletes go to the Trash.
- **No dependencies, no Xcode project** — plain Swift sources in `CallRecorder/`, built with `swiftc` via `./build.sh`.

## Quick start

Requirements: macOS 26 (Tahoe) or later, Xcode command line tools (`swiftc`).

```sh
git clone https://github.com/rai00007/call-recorder.git
cd call-recorder
./build.sh
open CallRecorder.app
```

The main window opens and a record icon appears in the menu bar. Click **Start Recording** (window or menu bar) and **Stop Recording** when done;
the recording appears in the library and is transcribed (and summarized, if Ollama is available). Nothing records until you click Start; you see a consent reminder first.

Existing `recordings/` folders next to the app are **copied** into the library on first launch (originals are never moved or deleted); Settings can re-run the import.

### Enable meeting minutes (optional)

```sh
# install Ollama from https://ollama.com, start it, then:
ollama pull qwen2.5:3b
```

Without Ollama you still get the audio and transcript.

### Permissions

On the first recording macOS asks for **Screen & System Audio Recording** (needed to capture the other side of the call)
and **Microphone**. If you miss the prompt, enable *Call Recorder* in System Settings → Privacy & Security.

`build.sh` signs with your first code-signing identity (or `CODESIGN_IDENTITY`) so permissions survive rebuilds.
With only an ad-hoc signature macOS invalidates them on every build — re-grant after each rebuild in that case.

## Where data lives

```
~/Library/Application Support/CallRecorder/Recordings/<id>/     (folder changeable in Settings)
  audio.m4a                # mixed audio
  system.m4a, mic.m4a      # raw tracks (Others / Me) — kept until YOU delete them
  transcript.txt           # original: [mm:ss] Me: / Others: ...
  transcript.edited.txt    # only if you edit the transcript
  minutes.md               # meeting minutes (needs Ollama)
  metadata.json            # title, status, action items
```

Example minutes:

```markdown
## Summary
The meeting set December 5th as the Q4 launch date for the mobile app.

## Action items
- [Me] Send the launch checklist to everyone (due: Friday)
- [Priya] Own the QA schedule (due: not stated)
```

## Configuration

Everything is in **Settings** (⌘,): storage folder, transcript language, Ollama endpoint and model, auto-summarize, launch at login, permissions.
`CALLREC_MODEL` and `OLLAMA_HOST_URL` env vars only provide the initial defaults. `CODESIGN_IDENTITY` selects the signing identity for `./build.sh`.

**Model guidance:** 3–4B models are fine for summaries but can slip on action-item owners. On Apple Silicon with 16 GB+, try a 7–8B model for better minutes. On Intel Macs stay at 3–4B; an hour-long meeting takes a few minutes to summarize.

## Privacy

Audio, transcripts and minutes never leave your machine. Speech recognition uses Apple's on-device models
(the model is downloaded once by macOS), and summarization talks only to your local Ollama server.
No analytics or telemetry; no account. Recordings live outside the repo; `recordings/`, audio files and the built app are git-ignored.

**Recording consent:** laws on recording calls vary by place and some require every participant's consent.
Tell people you're recording. You are responsible for complying with the law.

## Limitations

- Use headphones: with speakers your mic also hears the other side, so their lines can appear twice (as "Me" too).
- "Others" is one label — individual remote participants aren't told apart.
- Transcript accuracy depends on Apple's speech model; English (US) by default.
- Small local LLMs can make mistakes — skim the minutes before sharing.
- macOS 26+ only (uses the new Speech APIs).
- Changing the storage folder doesn't move existing recordings; they stay in the old folder (switch back to see them).
- After raw tracks are deleted, re-transcription uses the mixed audio and loses Me/Others labels.
- If the app is force-quit/crashes mid-recording, the unfinished audio may be unreadable; files are kept and flagged "Needs recovery".
- The screen-recording permission status in Settings can lag until relaunch.

## Troubleshooting

- **Start fails / no audio:** enable Call Recorder under System Settings → Privacy & Security → *Screen & System Audio Recording* and *Microphone*, then quit and reopen the app.
- **Permissions reset after every rebuild:** you're ad-hoc signed; create a code-signing identity (see `build.sh`).
- **Summary failed:** start Ollama and `ollama pull <model>`, check the endpoint in Settings (Test connection), then press *Retry summary*. The transcript is unaffected.
- **Transcription failed:** press *Retry transcription*; the first run downloads Apple's speech model.

## FAQ

**How do I record Zoom / Google Meet / Teams calls on a Mac without a bot?**
Call Recorder captures your Mac's system audio and microphone directly, so it works with any app and nobody sees a bot join.

**Is there a free, offline alternative to Otter.ai?**
This is one: on-device transcription plus a local LLM for summaries and action items, MIT-licensed.

**Can I use another LLM?**
Any model Ollama serves — set `CALLREC_MODEL`.

## Contributing

Issues and PRs are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Ideas: configurable language, summary templates,
speaker diarization for remote participants, Apple Foundation Models backend, global hotkey, auto-start on call detection.

## Files

- `CallRecorder/` — app sources: `App/` (entry, state), `Recording/` (capture, mixer, state machine), `Transcription/`, `Summarization/`, `Processing/`, `Storage/`, `Export/`, `Playback/`, `Views/`, `MenuBar/`
- `Tests/` — unit tests (`swift test`; logic only, with synthetic audio and fake transcripts)
- `build.sh` — compiles, signs and packages `CallRecorder.app`

## Manual test checklist

Not automatable (needs permissions, real audio): launch shows window + menu icon; consent reminder appears; Start/Stop in window and menu stay in sync (red icon, elapsed time); play audio while talking and confirm both mic and system indicators go active; recording appears with transcript (Me/Others) and minutes; playback seek/speed; search by title and a spoken word; stop Ollama and confirm the summary shows a retry button that works after restarting it; revoke Screen Recording and confirm a clear error; quit mid-recording and relaunch; Manage storage actions only trash raw tracks; export/copy; settings persist after relaunch.

## License

[MIT](LICENSE)
