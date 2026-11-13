# Call Recorder — open-source meeting recorder, transcriber & AI meeting minutes for macOS

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey)
![Swift](https://img.shields.io/badge/swift-single%20file-orange)

A tiny, **private, local-first** macOS menu-bar app that records any call or meeting
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
- **Single Swift file, no dependencies** — `main.swift` is the whole app; build with `swiftc`.

## Quick start

Requirements: macOS 26 (Tahoe) or later, Xcode command line tools (`swiftc`).

```sh
git clone https://github.com/rai00007/call-recorder.git
cd call-recorder
./build.sh
open CallRecorder.app
```

A record icon appears in the menu bar. Click **Start Recording**, and **Stop Recording** when done.

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

## Output

```
recordings/
  call_2026-11-12_14-30-00.m4a           # mixed audio
  call_2026-11-12_14-30-00.txt           # transcript: [mm:ss] Me: / Others: ...
  call_2026-11-12_14-30-00.minutes.md    # meeting minutes (needs Ollama)
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

| Setting | How | Default |
|---|---|---|
| Summary model | env `CALLREC_MODEL` | `qwen2.5:3b` |
| Ollama URL | env `OLLAMA_HOST_URL` | `http://localhost:11434` |
| Transcript language | `Locale(identifier: "en-US")` in `main.swift` | English (US) |
| Code-signing identity | env `CODESIGN_IDENTITY` | first valid identity, else ad-hoc |

Launch with env vars from a terminal: `CALLREC_MODEL=qwen2.5:7b ./CallRecorder.app/Contents/MacOS/CallRecorder`.

**Model guidance:** 3–4B models are fine for summaries but can slip on action-item owners. On Apple Silicon with 16 GB+, try a 7–8B model for better minutes. On Intel Macs stay at 3–4B; an hour-long meeting takes a few minutes to summarize.

## Privacy

Audio, transcripts and minutes never leave your machine. Speech recognition uses Apple's on-device models
(the model is downloaded once by macOS), and summarization talks only to your local Ollama server.
`recordings/` and the built app are git-ignored.

**Recording consent:** laws on recording calls vary by place and some require every participant's consent.
Tell people you're recording. You are responsible for complying with the law.

## Limitations

- Use headphones: with speakers your mic also hears the other side, so their lines can appear twice (as "Me" too).
- "Others" is one label — individual remote participants aren't told apart.
- Transcript accuracy depends on Apple's speech model; English (US) by default.
- Small local LLMs can make mistakes — skim the minutes before sharing.
- macOS 26+ only (uses the new Speech APIs).

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

- `main.swift` — the whole app (recording, mixing, transcription, minutes, menu bar)
- `build.sh` — compiles, signs and packages `CallRecorder.app`

## License

[MIT](LICENSE)
