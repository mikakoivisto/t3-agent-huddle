# 14 — Dictate instead of type

**Status:** proposed (phase 2 of 2), not built. Starts after [spec 13](13-write-and-send.md) is built and working · **Evidence:** none.

## Purpose and user value

- **Speak the message:** in any composer from spec 13 (a written answer, a message, a steer), click the microphone, talk, and the words appear in the text field.
- **Review before sending:** dictation fills the field and never sends by itself unless you turn that on. Speech recognition makes mistakes, and an agent acts on what it gets.

## Decisions this spec needs from the maintainer

| # | Decision | Recommendation |
|---|---|---|
| D1 | Which speech engines. | **Apple on-device** (default) and **Local server** (an OpenAI-compatible transcription endpoint on `127.0.0.1` that you run yourself, such as a Whisper server). Both keep audio on this Mac and need no new network rule. A **cloud** engine (OpenAI, others) would be a second exception to "Loopback only" plus an API key, so it stays an open question (DIC-Q1). |
| D2 | Bundle a model (for example whisper.cpp)? | No. The project has no third-party code, and the Apple engine downloads its own language assets through the system. |
| D3 | Auto-send when you stop talking. | Off by default, a setting to turn on. |

## Behaviour (proposed)

### In the composer

- **Microphone button** at the left of the composer's button row. Shown only when dictation is set up (below) and not in read-only mode.
- **Click to start:** the button turns lime with a pulsing dot, a level meter and a timer appear, and the words appear in the field as you speak. Words that may still change are grey, settled words are white (on the Apple engine; the local server returns the text when you stop).
- **Click again, or Esc, to stop.** The text stays in the field at the cursor, after anything already typed. Edit it, then Send as in spec 13. With "Send when I stop" on, it sends straight away using the composer's selected mode.
- **Long dictation:** the composer's expand button (spec 13) opens the bigger editor, where the microphone works the same. Dictating more than 6 lines in the small field suggests it with a one-line hint.
- **Limits:** one take is at most 2 minutes; the timer turns red for the last 10 seconds and recording stops at the limit.
- **Errors** (microphone denied, model missing, server unreachable) show as one line under the field, with a "Dictation settings…" link. The typed text is never lost.

### Settings: menu bar → "Dictation…"

A small window, built like the Inline approvals window:

| Setting | Values | Default |
|---|---|---|
| Engine | Apple on-device · Local server · Off | Off until chosen |
| Language | System language · a list from the engine | System language |
| Local server address | `http://127.0.0.1:<port>` only (same `LoopbackGuard` as the MCP) | empty |
| Local server model | free text, sent as `model` (for example `whisper-large-v3`) | empty |
| Send when I stop | on / off | off |
| Microphone | status line: allowed / not asked / denied, with "Open System Settings" when denied | — |
| Test | records 5 seconds and shows the text | — |

- **Apple on-device:** on macOS 26 and later, `SpeechAnalyzer` with `SpeechTranscriber`, on-device; the window shows "Language model: installed" or a **Download** button (the system downloads it). On macOS 14 and 15, `SFSpeechRecognizer` with on-device recognition required; a language without on-device support is shown as unavailable rather than falling back to Apple's servers.
- **Local server:** after you stop, the recording (16 kHz mono WAV, in memory) is posted to `<address>/v1/audio/transcriptions` with `model` and `language`. Bounded like every other request (`BoundedHTTP`).
- Settings live in `preferences.json`. They hold no secrets.

## Platform and permissions

- **Microphone permission** (`NSMicrophoneUsageDescription`) on first use. `NSSpeechRecognitionUsageDescription` is added for the macOS 14 and 15 path.
- **Ad-hoc signing:** macOS ties the microphone grant to the app's signature, so like the Keychain prompt, each new ad-hoc build asks again. Developer ID signing ends this.

## Security and privacy

- **Audio never leaves this Mac:** the Apple engine runs on-device with server fallback disabled; the local server must be a loopback address.
- **Audio is never written to disk** and is dropped when the take ends. The transcript is treated like typed text (spec 13: in memory, not logged).
- **The microphone is on only while the button shows recording.** No hotkey, no background listening, no wake word.
- **Read-only mode hides the microphone.**

## Acceptance criteria (proposed)

| ID | Statement | Tests |
|---|---|---|
| DIC-01 | Dictation never sends unless "Send when I stop" is on | new, with a scripted transcriber |
| DIC-02 | The local server address is refused unless it is `127.0.0.1` or `::1` | new, `LoopbackGuard` |
| DIC-03 | The Apple engine is created with on-device recognition required | new, source scan |
| DIC-04 | No audio file is written; recording stops at 2 minutes | new |
| DIC-05 | A transcription error keeps the typed text and shows the error | new |
| DIC-06 | Real dictation into a composer, on the Apple engine and against a local Whisper server | by hand |

## Open questions

- **DIC-Q1:** a cloud engine (OpenAI, others) with an API key in the Keychain vault and an https-only host list, as a second opt-in exception to "Loopback only"?
- **DIC-Q2:** push-to-talk with a global hotkey? It needs Accessibility or Input Monitoring permission, so it is out of scope here.
- **DIC-Q3:** which local servers to name in the docs as tested?

## Sources

`docs/specs/13-write-and-send.md`, `docs/specs/12-non-functional-rules.md` (S1 loopback only), AGENTS.md (no third-party dependencies).
