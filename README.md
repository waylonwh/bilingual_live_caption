# Bilingual Live Caption

A native macOS app that captures computer audio once and displays original and translated captions in a floating window.

Choose either transcription mode while captions are running:

| Original captions | Translation | Estimated API cost |
| --- | --- | --- |
| Apple `SpeechAnalyzer` + `SpeechTranscriber`, on device | `gpt-realtime-translate` | US$2.04/hour |
| OpenAI `gpt-live-transcribe` | `gpt-realtime-translate` | US$3.06/hour |

Both models receive audio in parallel. Translation never waits for the original transcript. Switching transcription keeps the translation connection open. The Apple mode uses the public Speech API.

## Requirements

- Apple silicon Mac, macOS 27 or later.
- Xcode 27 or later to build. There are no third-party packages.
- Your own OpenAI API key with access to the selected models and API billing enabled.
- System audio recording permission for this app. Screen capture is not used.
- For Apple transcription, a supported source language and its downloaded speech model.

## Build and open

```sh
bash scripts/build-app.sh
open "dist/Bilingual Live Caption.app"
```

The build scripts keep compiler caches in this project. The app is locally ad-hoc signed; it is not notarized or installed into Applications. Rebuilding may require macOS to renew recording permission.

1. Choose **Apple on-device** or **OpenAI cloud**.
2. Choose the spoken language and translation language.
3. For Apple mode, use **Prepare Apple Model** if the configuration is not ready. This may download system-managed language assets; it only does so when you press the button.
4. Leave **All computer audio** selected, or refresh the source list and select an app. Starting capture may prompt for system audio recording permission; after granting it, restart the app if macOS requests it. Listing apps does not start capture or request recording permission.
5. Enter your API key. After a short pause, it is saved in macOS Keychain; **Save** saves immediately. Check the message below the field to confirm success. Clearing the field removes this app's saved key. The key is never written into ordinary preferences or logs. You can alternatively launch with `OPENAI_API_KEY` set when no key is saved.
6. Press **Start Captions**. This sends the selected audio to OpenAI and starts paid API usage.
7. Change the transcription selector while listening. If the replacement cannot start, the previous mode remains active.
8. Press **Stop** to end capture and close API sessions. Closing the controls window alone does not stop captions. The menu bar icon can reopen controls, show captions, stop, or quit.

**Preview** shows sample captions without audio capture, model downloads, or API calls. It is not a speech recognition test.

The app remembers transcription mode, languages, audio source, keywords, font sizes, colors, opacity, and caption-window visibility. macOS restores both windows' position and size. Audio sources are saved by application bundle identifier rather than process number. A selected app must be running when capture starts; it never silently falls back to all computer audio. Reopening restores preferences without starting capture, connecting to OpenAI, or restoring previous caption text.

The API key uses a non-synchronizing Keychain item belonging to this app. macOS may ask for Keychain access, particularly after rebuilding this locally ad-hoc-signed app. A denied request is reported in controls; the app never falls back to storing the key as plain text. Settings from older versions that stored everything only in memory must be entered once in this version.

The caption window contains only original and translated text on a background, with no title bar, buttons, labels, or status messages. Drag the text or background to move it; drag its outer edge to resize. Use controls to set each text's size and color plus the background color and opacity. Original and translated text scroll independently with the scroll wheel or trackpad.

Use **Hide Caption Window** in controls or **Hide Captions** in the menu bar to dismiss it. Click the caption window and press **Esc** to hide it, or use **Command-L** while the app is active to toggle visibility. Hiding the window does not stop transcription or API usage; use **Stop** to end the session. The window stays above ordinary windows and requests visibility across Spaces and alongside fullscreen apps; fullscreen and multi-display behavior still need testing on the target setup.

## Audio and caption behavior

- System/application output is captured with a private Core Audio Process Tap. No screen capture session or video output is created. Microphone input is not captured. All-computer capture excludes this app. The tap leaves the original audio playing and does not change the default output device.
- The temporary audio device is destroyed when capture stops. An audio format change stops captions with a message to restart. Protected media may still restrict audio capture; playback and audio availability need verification with the particular player.
- Audio is normalized to 24 kHz, mono, signed 16-bit PCM and paced in 200 ms frames. Silence is sent when capture provides no audio, as required by the translation protocol.
- OpenAI transcription uses the `low` delay setting. This model does not support server VAD, so a simple client-side energy threshold commits turns after 800 ms of quiet, with a 15-second maximum turn. Very quiet audio and continuous music can affect segmentation.
- Apple uses volatile results for prompt display, then replaces them with final text. Audio conversion uses Apple's `AnalyzerInputConverter`.
- Keywords are comma-separated hints for the transcription branch. The translation model does not support custom terminology prompts.
- The translation session's optional source transcription is disabled. Translated audio is received and discarded; only text is displayed. Discarding audio does not reduce the translation price.
- Original and translated text are independent interpretations of the same audio. They may differ, arrive at different times, and break sentences differently. The UI does not imply exact sentence or word alignment.
- Each lane starts a new line for each sentence using Apple's local Natural Language tokenizer. Unfinished text appears immediately; a sentence-ending mark alone does not create an empty next line. Long sentences still wrap to the window width. The formatter runs only when text or language changes, without a timer, additional API requests, or changes to audio commits. Transcript revisions replace the displayed text and recalculate sentence boundaries, so corrections can still move a line break. Missing or ambiguous punctuation can prevent reliable sentence separation.
- A mode switch can leave the last unfinished original-language phrase incomplete. Translation continues without restarting. New original captions begin with audio received after the replacement transcriber is ready.
- Recent caption text is kept in memory. Nothing is recorded or exported automatically.
- Network errors, expiring sessions, or a backlog of more than about two seconds stop capture and close sessions, with a visible error. Restart is manual so the app never silently retries paid sessions. Final translation is drained on normal stop, with a bounded timeout and a warning if draining fails.

## Cost and privacy

Rates were checked on 2026-10-01: translation US$0.034/minute, cloud transcription US$0.017/minute. The displayed estimate counts audio frames and the selected mode; it excludes tax, initialization/switch overlap, and any unconfirmed billing adjustments. It is not an invoice. Check the OpenAI usage dashboard for actual charges.

Apple mode performs original-language recognition locally, but the same audio still goes to OpenAI for translation. The full app is not offline. Starting capture and downloading a language model are separate explicit controls.

## Validation

Audio conversion tests use synthetic stereo input at 44.1 and 48 kHz, with both interleaved and separate channel buffers. They check duration, signal level, silence, and rejection of changed channel layouts without starting system audio capture. Protected-video playback has not been verified with the new capture backend.

Sentence-formatting tests cover English abbreviations, decimals, domains, ellipses and quotes, Chinese and Japanese sentences, character-by-character arrival, unfinished text, corrected transcripts, clearing captions, and independent original/translation updates. UI previews include a taller caption window to inspect sentence breaks in both lanes.

```sh
bash scripts/swift-local.sh test
```

Offline tests cover PCM framing, silence, backlog limits, turn boundaries, partial/final caption replacement, out-of-order completions, API message formats, final-text draining, API-key redaction, settings restoration, and credential-store failures. Settings and credentials use isolated test stores; these tests do not access your actual API key. A window test checks that clicks reach native window dragging before the scroll views, and that Escape and Close invoke dismissal. It does not simulate an actual desktop drag. The release app builds and passes local signature verification. Both mode selectors and the caption window have been inspected in offscreen UI renders.

The app icon is a layered Icon Composer document at `Resources/AppIcon.icon`, with vector foreground assets and system-rendered background and effects. `scripts/build-icon.sh` compiles it through Apple's asset compiler; the app includes `Assets.car`, a compatibility `.icns`, and the compiler-generated icon metadata. The earlier PNG remains as a design reference and is not used in the application bundle. `scripts/check-app-icon.swift` exports the icon returned by macOS's file-icon service for visual inspection.

Compilation and UI preview do not establish live API access, recognition quality, real-world latency, or system capture permission. No paid API calls or language-model downloads were made during development. Interactive app launch and fullscreen behavior still require verification on the desktop.

## References

- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple speech transcription introduction](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Apple Core Audio Process Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple Icon Composer workflow](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [Apple Keychain Services](https://developer.apple.com/documentation/security/adding-a-password-to-the-keychain)
- [OpenAI realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)
- [OpenAI realtime translation](https://developers.openai.com/api/docs/guides/realtime-translation)
- [Translation client events](https://developers.openai.com/api/reference/resources/realtime/translation-client-events)
- [API pricing](https://developers.openai.com/api/docs/pricing)


## Generative AI usage

This project was developed with assistance from generative AI tools. Not all code has been reviewed by a human. Use at your own risk.
