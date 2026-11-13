# Call Recorder

A tiny macOS menu-bar app that records your calls (Zoom, Meet, Teams, FaceTime, …) and
transcribes them on-device. Hand the result to ChatGPT to get a cleaned-up transcript,
summary and action items.

- Records **system audio** (the other participants) + **your microphone**, mixed into one `.m4a`
- Works with any app — it captures audio from the Mac, it doesn't join the meeting
- Transcribes locally with macOS's built-in speech model (no API key, nothing uploaded)
- Labels the transcript **Me** (your mic) vs **Others** (system audio)
- Writes meeting minutes (summary, discussion points, decisions, action items) with a local LLM via [Ollama](https://ollama.com)
- Saves to `recordings/` inside this repo

Requires macOS 26 and Xcode command line tools (`swiftc`).

## Build & run

```sh
./build.sh
open CallRecorder.app
```

A record icon appears in the menu bar. Menu:

| Item | What it does |
|------|--------------|
| Start Recording | Starts capturing system audio + mic (icon turns red) |
| Stop Recording | Stops, mixes to one file, transcribes, then reveals it in Finder |
| Open Recordings Folder | Opens `recordings/` |
| Quit | Stops and saves any recording in progress, then exits |

### First-run permissions

On the first recording macOS asks for permissions. If it doesn't, or you denied them, enable
**Call Recorder** in System Settings → Privacy & Security:

- **Screen & System Audio Recording** (needed to capture the other side of the call)
- **Microphone**

`build.sh` signs with your first code-signing identity (or `CODESIGN_IDENTITY`) so permissions survive rebuilds; with only an ad-hoc signature macOS silently invalidates them on every build.

### Meeting minutes (optional)

Install Ollama from ollama.com, start it, then `ollama pull qwen2.5:3b`. After you stop a recording the app
writes `.minutes.md` next to the transcript. If Ollama isn't running you still get the audio and transcript.
Set `CALLREC_MODEL` to use another model (e.g. `qwen2.5:7b` on Apple Silicon / 16 GB+). On Intel Macs
stick to ~3-4B models; an hour-long meeting takes a few minutes to summarize.

## Output

```
recordings/
  call_2026-11-12_14-30-00.m4a   # the audio — upload this to ChatGPT
  call_2026-11-12_14-30-00.txt   # transcript: [mm:ss] Me:/Others: ...
  call_2026-11-12_14-30-00.minutes.md  # minutes (needs Ollama)
```

If transcription fails, the `.m4a` is still saved.

## Using it with ChatGPT

Upload the `.txt` (or the `.m4a`) and prompt something like:

> This is a transcript of a meeting. Clean it up, label speakers where you can, then give me
> a summary, key decisions, and action items with owners.

## Notes

- Transcript language is English (US); change `Locale(identifier: "en-US")` in `main.swift`.
- The first transcription downloads the speech model once. If `SpeechTranscriber` isn't available on your Mac, it falls back to `DictationTranscriber`.
- Use headphones: with speakers, your mic also hears "Others", so their lines appear twice (as Me too).
- Tell participants you're recording — some places legally require everyone's consent.
- `recordings/` and the built app are git-ignored.

## Files

- `main.swift` — the whole app (recording, mixing, transcription, menu bar)
- `build.sh` — compiles and packages `CallRecorder.app`
