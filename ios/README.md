# FreeFlow for iOS

FreeFlow for iOS is a dictation keyboard plus a small containing app. You tap
the mic on the FreeFlow keyboard, speak, and the cleaned-up text is inserted
into whatever field you're typing in. It uses the same OpenAI-compatible
transcription and cleanup pipeline as the Mac app, Groq by default, and you
never leave the app you're typing in.

The macOS app is unaffected: it is still built by the root `Makefile` with
`swiftc`. The iOS code lives under `ios/`. "Code layout" lists the exceptions:
the shared `Sources/` files, the Core tests in `Tests/`, and the CI tooling.

## How in-keyboard dictation works

iOS doesn't let a keyboard extension record audio itself. The audio session
activates, but input never starts, even with Full Access. WebKit can record,
though. Its GPU process captures on the extension's behalf and attributes the
capture to the containing app's microphone permission.

The keyboard uses that as follows:

1. Keep a 2×2 pt web view at alpha 0.02 in the keyboard's window. It must
   stay in the window, because WebKit mutes pages that are hidden or
   detached. It loads a small inline page from a fake `https` origin, which
   makes the page a secure context.
2. On tap, the page calls `getUserMedia` and runs a `ScriptProcessor`. A
   Kaiser-windowed polyphase filter downsamples the audio to 16 kHz Int16.
   The page posts base64 chunks to Swift, and every chunk is acknowledged. If
   the acknowledgements stop, the page releases the microphone by itself.
3. Swift streams the chunks into a 16 kHz mono WAV, the same format the Mac
   app uploads. At stop it applies a single capped, noise-guarded gain (iOS
   gives the page no automatic gain), then sends the file through the shared
   `TranscriptionService` and `PostProcessingService`.
4. The text is inserted with `textDocumentProxy`, but only if the field hasn't
   changed since recording started.

Raycast's iOS keyboard ships this same technique, as do several open-source
projects (see "Credits"). It is undocumented, though. Apple could close it in
any iOS release, and App Review may treat it as a grey area.

For those cases there is a **fallback**. The keyboard offers to record in the
FreeFlow app instead when:

- no audio arrives in time: 4 seconds for the first dictation after the
  keyboard opens, while WebKit's media process starts, and 2 seconds after
  that;
- capture is unavailable (Lockdown Mode, low memory);
- the page fails.

The fallback works like this:

- The keyboard opens `freeflow://dictate?session=<id>`. Keyboards can't do
  this through public API, so it walks the responder chain to the app object.
- The app starts recording on its own only for the session the keyboard is
  waiting for. Any other `freeflow://` link opens an idle recorder that waits
  for you to tap Start.
- The app records, processes, and hands the text back through the App Group.
- iOS has no API for returning to the previous app. You swipe back (or use
  the "◀︎ App" breadcrumb), and the keyboard inserts the result if you're in
  the same field. In any other field it offers a one-tap "Insert from
  FreeFlow" instead.

## Requirements

- iOS 17 or later, iPhone.
- The FreeFlow app must have microphone permission. The keyboard borrows it.
- The keyboard must be added in Settings → General → Keyboard → Keyboards,
  with **Allow Full Access** on. Full Access is what lets the keyboard reach
  the network and read the shared API key and settings. Without it, the
  keyboard can still type a space, delete and return, and it explains what's
  missing.
- An API key for Groq or another OpenAI-compatible provider. It is entered in
  the app and stored in a keychain group shared with the keyboard.

## Code layout

| Path | What |
|---|---|
| `ios/FreeFlow/` | The containing app (SwiftUI): onboarding, Home with a try-it field and setup checklist, Settings, History, and the fallback recorder. |
| `ios/FreeFlowKeyboard/` | The keyboard extension (UIKit): the dictation-first panel and its controller. |
| `ios/Shared/Core/` | Foundation-only logic shared by both targets: settings, pipeline routing, history, handoff, the audio core (WAV, PCM, gain, chunk decoding, the capture page source), and the keyboard state machine. The macOS `make test` runner also compiles and tests it. |
| `ios/Shared/Platform/` | iOS-only shared code: the App Group and keychain stores, and `WebAudioCapture`. |
| `ios/FreeFlowTests/`, `ios/FreeFlowUITests/` | XCTest unit tests (simulator) and UI tests, including driving the keyboard. |
| `ios/Config/` | `FreeFlow.xcconfig` (shared settings), `Local.xcconfig.example`, and the TestFlight export options. |
| `Tests/IOS*CoreTests.swift` | `make test` tests for `ios/Shared/Core`, in the house style of `Tests/TestSupport.swift`. Put tests for Core code here, not in `ios/FreeFlowTests`, so `make check` covers them. |
| `.github/workflows/ios*.yml`, `.github/scripts/`, Makefile `ios-*` targets | CI (simulator tests, screenshots, the TestFlight upload) and the matching local commands. |
| `../Sources/*.swift` (a listed subset) | The Mac pipeline files, compiled into both iOS targets by explicit reference: `TranscriptionService`, `PostProcessingService`, `LLMAPITransport`, `TranscriptTextCore`, `AppContext`, `LLMCooldownManager`, `ModelConfiguration`, `TemperatureCapabilityCache`, `ContextInferenceFailure`, `TranscriptionErrorPresentationCore`, `NetworkMonitor` and `LiveAudioLevelNormalizer`. `APIConfigurationDraft` goes into the app only. |

The project, `ios/FreeFlow.xcodeproj`, uses folder-synchronized groups, so new
files under those folders need no project edits. Only the list of shared
`../Sources` files is maintained by hand.

## Building and testing

Every check runs on GitHub Actions; no local Mac is needed.

- `.github/workflows/ios.yml` runs on pull requests into `main`, on pushes to
  `ios-wip/**` branches, and by hand (`gh workflow run ios.yml --ref <branch>`).
  It does the following:
  - builds the app and keyboard for the iOS 26.5 simulator;
  - runs the unit tests, including the WebKit capture tests against the
    simulator's mock microphone;
  - enables the keyboard with Full Access in the simulator and runs the UI
    tests that drive it, against a local mock of the provider API
    (`.github/scripts/mock-openai-server.py`);
  - uploads screenshots as artifacts;
  - on pull requests and manual runs, checks that the project also builds with
    the Xcode 27 preview. That check is informational and never blocks a merge.
- `make check` (the Mac checks) also compiles and tests the Foundation-only
  code in `ios/Shared/Core`.

On a Mac with Xcode 26 or later, the unit and UI tests run locally after the
same setup CI does. Use a throwaway simulator: the prepare step writes its
privacy database and reboots it.

```bash
UDID=<a booted iPhone 17 simulator's UDID>
make ios-build IOS_DESTINATION="platform=iOS Simulator,id=$UDID"
make ios-simulator-prepare IOS_SIMULATOR_UDID=$UDID  # keyboard + Full Access
make ios-mock-provider                               # leave running in a second terminal
make ios-test IOS_DESTINATION="platform=iOS Simulator,id=$UDID"
```

`make ios-test` also runs the screenshot suite, which CI runs as a separate
job, so a local run takes about 10 minutes longer.

Simulator builds are signed ad hoc
(`CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`). That keeps
the App Group and keychain entitlements. `CODE_SIGNING_ALLOWED=NO` would
silently drop them.

**Keep the project format at Xcode 16 (`objectVersion = 77`).** If you open
the project in Xcode 27, don't accept a project-format upgrade: Xcode 26.6 on
CI can't read the newer format.

## Installing on an iPhone

The main path is TestFlight from CI, which needs no Mac. Follow
[`TESTFLIGHT.md`](TESTFLIGHT.md) for the one-time setup in the browser, then
run the **iOS TestFlight** workflow by hand. It archives, cloud-signs,
verifies the entitlements and uploads the build for internal testing only.

To build from Xcode instead, copy `ios/Config/Local.xcconfig.example` to
`ios/Config/Local.xcconfig`, set `DEVELOPMENT_TEAM` and your bundle-ID prefix,
open `ios/FreeFlow.xcodeproj`, pick your iPhone and press Run. Don't set the
team in Xcode's Signing pane; `Local.xcconfig` is gitignored and overrides
the shared settings.

## Privacy

FreeFlow has no server. What leaves the phone:

- Each dictation's audio goes to your configured transcription provider.
- The transcript then goes to your configured LLM provider for cleanup.
  - With "Preserve exact wording" on, it skips the LLM, unless an Output
    Language is set. Then it's still sent, for a literal translation.
  - A matching voice macro sends nothing to the LLM.
- The iOS app sends **no surrounding document text** as context. Cleanup gets
  the same "context disabled" input the Mac app uses when context capture is
  off.
- Nothing else: no analytics, telemetry or crash reporting.

What stays on the phone:

- **API keys:** in the keychain, readable after first unlock, never synced.
- **Settings:** in the App Group.
- **History:** the last 20 dictations as text only, with no audio. It can be
  turned off or cleared in Settings.
- **Fallback results:** text recorded in the app for the keyboard waits in
  the App Group until one of these happens:
  - the keyboard inserts it, or you dismiss it, dictate again, or hide the
    keyboard after it has offered the text for a couple of seconds;
  - you clear or turn off history;
  - it expires (3 minutes) and the keyboard next appears or FreeFlow next
    opens.

  A keyboard that iOS stops, or that shows for only a moment, leaves the text
  for the next keyboard, which offers it again in whichever app it appears.
- **Recordings:** deleted after transcription. After a failed upload the app
  keeps the file so you can try again, until you close the recorder.

Logs record only states, counts and durations. They never contain
transcripts, audio, keys or URLs.

## Limitations and risks

- **The technique is undocumented.** If Apple closes it, the fallback keeps
  dictation working, but it bounces you to the app.
- **App Review.** Guideline 4.4.1 expects keyboards to provide typing without
  Full Access and not to launch other apps. This dictation-first panel and its
  fallback are fine for TestFlight internal testing, but an App Store
  submission would need a typing layout and a review of the fallback.
- **Memory.** Keyboard extensions are killed silently at roughly 60–90 MB.
  The keyboard checks free memory before recording, streams audio to disk,
  and caps recordings at 5 minutes.
- **Fields the keyboard can't reach.** Secure fields, phone-number pads and
  some apps always use the system keyboard.
- **Host app identity.** Since iOS 26.4, a keyboard can't tell which app it's
  in, so the fallback can't send you back automatically.

## Credits

The WebKit capture approach comes from Kevin Picchi's thread (Nov 19 2026),
which describes how Raycast's iOS keyboard does it. These MIT-licensed
projects helped shape the implementation:
[stephancill/ios-keyboard-dictation](https://github.com/stephancill/ios-keyboard-dictation),
[plotarmordev/inplace-dictation-keyboard](https://github.com/plotarmordev/inplace-dictation-keyboard)
and [anomalyco/hex](https://github.com/anomalyco/hex).
