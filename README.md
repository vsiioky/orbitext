# Orbitext

A standalone Telegram client for Apple Watch. It works without an iPhone.

> Orbitext is an unofficial, independent client for Telegram on Apple Watch. It uses the Telegram API and is part of the Telegram ecosystem, but it is not affiliated with, endorsed by, or sponsored by Telegram FZ-LLC or Telegram Messenger Inc. "Telegram" and the Telegram logo are trademarks of Telegram FZ-LLC; the name is used here only to describe compatibility.

Orbitext is written in Swift and talks to Telegram directly over MTProto through
[TDLib](https://github.com/tdlib/td) 1.8.64 (the `tdjson` C API). It targets
watchOS 26 and later.

## Status

Orbitext is in beta (version 0.1.0) and is looking for testers. Expect rough
edges, and please report what you find: open an issue at
https://github.com/vsiioky/orbitext/issues. See
[Testing and bug reports](#testing-and-bug-reports) for what to include.

## Screenshots

<!-- Screenshots will be added here. -->

## Features

**Messages**
- Text, photos, videos, voice notes, stickers, GIFs, and documents
- Animated stickers and emoji (TGS rendered with rlottie)
- Video messages (round videos) and audio
- Forwarded messages with the original sender, replies with a quoted preview
- Reply, forward, edit, and delete
- Quick replies and emoji shortcuts
- Reactions, including custom emoji
- Typing indicators and date separators
- Older messages load automatically as you scroll up
- Service messages: calls, contacts, locations, pinned messages, joins and leaves
- Basic bot support: command menu and inline keyboards

**Chat list**
- Filter by Telegram folder
- Pinned chats section
- Unread counters with a muted badge
- Swipe actions: pin, mute, mark as read
- Draft indicator, pull to refresh, loading skeletons

**Media**
- Record and send voice messages (M4A, 16 kHz) and share a location
- Send stickers
- Audio playback with a progress bar and Now Playing
- Audio format detection (OGG, M4A, MP3, WAV)
- Video messages and videos through the WatchKit movie player
- Photo zoom with the Digital Crown

**Sign-in**
- QR code (scan it from the Telegram app on your phone)
- Phone number and login code
- Two-step verification password with hint

**Background work and notifications**
- Background App Refresh with local notifications
- Notifications grouped by chat, with reply and mark-as-read actions
- Notification decisions follow current TDLib state: mute settings (including
  per chat type), messages already read on another device, and folder filter
- The TDLib receive loop and network monitor pause in the background

**Widget**
- Unread counter (circular, corner, rectangular, inline) and last-chat preview
- Shares state with the app through an App Group

**Settings and other**
- Folder filter, notifications, language (system, English, Russian, Kazakh),
  cache size and cleanup, log out
- Contacts with local search, global message search, profiles with online status
- LRU disk cache and in-memory image cache
- Localized in English, Russian, and Kazakh

## Known limitations

Orbitext is not a full Telegram client. Currently not supported:

- Secret chats (end-to-end encrypted chats)
- Voice and video calls
- Sponsored messages in channels. Telegram's API terms require them for apps
  that show channels; this is a known gap and not yet implemented.
- Self-destructing media. Handling is in progress; until it is finished,
  such media may not display correctly.
- Sending photos, videos, or files from the watch (stickers, voice notes, and
  locations can be sent)
- Sticker pack browsing, scheduled messages, polls, topics in supergroups,
  stories, and Telegram Premium features

## Requirements

- An Apple silicon Mac
- Xcode 27.1 (the Xcode 27.0 beta hangs the unit-test runner on the watchOS
  simulator)
- watchOS 26.0 or later. The app targets arm64 watches: Apple Watch Series 9
  and later, Ultra 2 and later, SE 3
- Swift 6 (the language mode of every target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), SwiftFormat, and
  ripgrep. Versions the project is tested with: xcodegen 2.46.0,
  swiftformat 0.64.5, ripgrep 15.x, plus Python 3. Other versions may
  produce false failures in `scripts/verify.sh`.

  ```bash
  brew install xcodegen swiftformat ripgrep
  ```
- To build TDLib from source only: `cmake` and `gperf`

## Build from source

### 1. Clone

```bash
git clone https://github.com/vsiioky/orbitext.git
cd orbitext
git config core.hooksPath .githooks
```

The vendored rlottie package lives in `Packages/librlottie/` as ordinary
files, so `--recursive` is not needed (see its `README.md`).

### 2. TDLib libraries

The prebuilt static TDLib and OpenSSL archives (about 250 MB) are not stored in
the repository. They are pinned by SHA-256 in `scripts/tdlib/libs.sha256` and
must end up in:

```
TDLib/
  lib-device/       watchOS arm64 + arm64_32, 14 archives
  lib-simulator/    simulator arm64, same set
```

There are no TDLib headers: the `tdjson` entry points are declared in the
bridging header `Orbitext/Telegram/TDJsonClient.h`.

Option A, download the prebuilt libraries. Until the first `tdlib-libs`
release is published, use option B. The maintainers publish them as the
`tdlib-libs` asset of a release at
https://github.com/vsiioky/orbitext/releases. Pass the asset URL:

```bash
TDLIB_LIBS_URL=<url of the tdlib-libs tarball> scripts/tdlib/fetch-libs.sh
```

Every file is checked against the manifest.

Option B, build from source (about 10 minutes on a recent Apple silicon Mac).
You need a TDLib checkout at commit `89ebded9571b7bb589ec1bd05e585fffa4c580e2`
(TDLib 1.8.64) and the OpenSSL 3.4.0 sources. The two patches in
`native-patches/` are applied by the script.

```bash
git clone https://github.com/tdlib/td.git ../td
git -C ../td checkout 89ebded9571b7bb589ec1bd05e585fffa4c580e2
# download and unpack openssl-3.4.0.tar.gz from https://www.openssl.org/source/
scripts/tdlib/build-all.sh --td ../td --openssl ../openssl-3.4.0 --install
```

Check the result with `scripts/tdlib/verify-libs.sh`.

### 3. Telegram API credentials

Every app must use its own `api_id` and `api_hash`. Register your application at
https://my.telegram.org/apps, then copy the example file and fill it in:

```bash
cp Orbitext.xcconfig.example Orbitext.local.xcconfig
```

```xcconfig
TDLIB_API_ID = your_api_id
TDLIB_API_HASH = your_api_hash
```

`Orbitext.local.xcconfig` is gitignored. Never commit credentials. Unit tests
do not need them.

### 4. Signing (device builds only)

Simulator builds and tests do not need a signing team. To run on a real watch,
copy the example and set your Apple Developer Team ID:

```bash
cp Signing.local.xcconfig.example Signing.local.xcconfig
```

`Signing.local.xcconfig` is gitignored. The bundle identifiers
(`com.orbitext.*`) and the App Group (`group.com.orbitext.shared`) belong to the
maintainer. For your own device builds use your own identifiers (see
[Telegram API terms](#telegram-api-terms-for-forks)).

### 5. Open, build, and verify

`Orbitext.xcodeproj` is generated from `project.yml` and committed. Open it in
Xcode, or regenerate it after changing `project.yml` or adding, removing, or
renaming files:

```bash
xcodegen generate
```

Never edit `project.pbxproj` by hand.

| Scheme | Purpose |
|--------|---------|
| `OrbitextWatch` | the watch app; unit tests with coverage |
| `OrbitextWatchTSan` | the same tests under Thread Sanitizer |
| `Orbitext` | iOS companion stub that wraps the watch app for App Store Connect; not run on its own |
| `OrbitextLiveQA` | UI checks against an already signed-in session; manual, maintainers only |

Before committing code, run the gate:

```bash
scripts/verify.sh            # TDLib hashes, xcodegen sync, release checks, SwiftFormat, tests, coverage
scripts/verify.sh --no-tests # static checks and a build only
scripts/verify.sh --tsan     # unit tests under Thread Sanitizer
```

If `xcode-select` points at a beta, run with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The tests run on a
dedicated simulator named "Orbitext Verify", created automatically, so they do
not touch your manual runs. Pull requests are checked by a hosted lint job;
the full build and tests run on pushes to `main` on the maintainer's Mac.

## Testing and bug reports

TestFlight: coming soon.

When you report a bug at https://github.com/vsiioky/orbitext/issues, please
include:

- watch model and watchOS version (for example Apple Watch Series 10, watchOS 26.1);
- Orbitext version and build number (TestFlight shows the build);
- how you installed it (TestFlight, built from source, simulator);
- steps to reproduce, what you expected, and what happened;
- screenshots or a screen recording, with private chats hidden;
- crash reports if the app crashed (TestFlight feedback attaches them).

Release builds have no log export yet. Debug builds can write TDLib request
telemetry to the system log. Whatever you attach, remove phone numbers, names,
message text, login codes, and anything else private. Report security problems
privately, see [Security](#security).

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first: it
covers the workflow, code rules, checks, and the commit format. Every
contributor must sign the Contributor License Agreement ([CLA.md](CLA.md)); a
bot guides you through it on your first pull request. Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Architecture

```
Orbitext/
  App/          AppState, AuthManager, ChatRepository, ChatStore, MessageManager,
                ErrorPresenter, lifecycle and push coordination
  Models/       AuthState, ChatModel, MessageModel, ContactModel, FolderModel,
                BotKeyboard, FormattedString
  Telegram/     TelegramServiceProtocol and capability protocols; TDLibService
                (+Auth, +Updates, +Chats, +Messages, +Reactions, +Files, +Bots,
                +Attachments, +Parsers, +NameResolver) and its parts:
                TDClientSession, TDRequestSender, AuthCoordinator, PushRegistrar,
                PresenceController, TDJsonWrapper, TDLibEvent; Generated/ holds
                the TDLib bindings produced by scripts/codegen.sh
  Services/     BackgroundRefreshScheduler, DraftStore, HapticManager,
                LottieRenderer, MessageQueue, NetworkMonitor,
                NotificationManager, VoiceManager, LocationProvider
  Cache/        ImageCache (LRU over TDLib files, with priorities and
                cancellation), SharedPlaybackFiles, ListCache
  Utilities/    Logger and small helpers
  Resources/    Localizable.strings (en, ru, kk)
  Vendor/       QRCodeGenerator (pure Swift, no dependencies)
  Views/
    Auth/        QR login, phone, code, two-step password
    Chat/        Messages, stickers, media, voice player and recorder,
                 reactions, profile, video, bot keyboards
    ChatList/    Chat list and skeleton loading
    Components/  Avatar, connection status, typing indicator, time formatting
    Compose/     Text, quick replies, emoji, voice
    Contacts/    Contact list and search
    Search/      Global message search
    Settings/    Folder filter, notifications, language, cache, log out
OrbitextTests/    Unit tests
OrbitextUITests/  Live UI checks (maintainers)
OrbitextWidget/   WidgetKit extension
OrbitextStub/     iOS companion stub for App Store Connect
Packages/         librlottie, vendored rlottie as a SwiftPM package
native-patches/   Two TDLib patches applied by scripts/tdlib/build-all.sh
scripts/          verify.sh, TDLib tooling (scripts/tdlib), codegen, release checks
docs/             GitHub Pages site (landing and privacy pages), release docs
```

Key decisions:

- **`@Observable`** (Observation framework) instead of `ObservableObject` and
  `@Published`.
- **`TelegramServiceProtocol`** and `AsyncStream<TDLibEvent>` make the app
  event-driven. App code outside `Orbitext/Telegram/` never names the TDLib
  transport types; `scripts/verify.sh` enforces this.
- **`TDJsonWrapper`** is an async/await wrapper over the `tdjson` C API that
  matches requests to responses with `@extra`.
- **NSDictionary bridging.** Nested TDLib objects are re-serialized through
  `JSONSerialization` before they are bridged into Swift.
- **`LottieRenderer`** uses the rlottie C API and zlib to render TGS
  animations frame by frame.
- **Background refresh** uses `WKApplication.scheduleBackgroundRefresh` with
  `.backgroundTask(.appRefresh)`.
- **Folders** use `updateChatFolders` and `chatListFolder` to load chats from
  the selected folder.
- **Swift 6** is the language mode of every target. `TDLibService` and its
  parts are `Sendable` without `@unchecked`, and the state of each part sits
  behind one `Mutex`. A data race the compiler can see is an error, and
  `scripts/verify.sh` also fails on concurrency warnings in app code.
- **Localization** uses `String(localized:)` and `.strings` files (en, ru, kk).

Project configuration:

| Setting | Value |
|---------|-------|
| Bundle ID (iOS stub) | `com.orbitext.app` |
| Bundle ID (watch app) | `com.orbitext.app.watchkitapp` |
| Bundle ID (widget) | `com.orbitext.app.watchkitapp.OrbitextWidget` |
| App Group | `group.com.orbitext.shared` |
| Bridging header | `Orbitext/Telegram/TDJsonClient.h` |
| Minimum OS | watchOS 26.0 |
| TDLib | 1.8.64 (`89ebded`), OpenSSL 3.4.0 |

## Security

Please report vulnerabilities privately, not in public issues. See
[SECURITY.md](SECURITY.md).

## Telegram API terms (for forks)

Orbitext uses the Telegram API and follows the
[Telegram API Terms of Service](https://core.telegram.org/api/terms). If you
fork Orbitext and distribute builds:

- use your own `api_id` and `api_hash`, registered at
  https://my.telegram.org/apps. Do not reuse the maintainer's;
- do not use the Orbitext name, icon, bundle identifiers (`com.orbitext.*`), or
  App Group (`group.com.orbitext.shared`); see [TRADEMARKS.md](TRADEMARKS.md);
- tell users that the app uses the Telegram API and is part of the Telegram
  ecosystem, and that it is unofficial. A name that contains "Telegram" must be
  preceded by "Unofficial";
- do not use the official Telegram logo;
- do not add ghost mode, faked online or read status, or anything else that
  interferes with Telegram's core functionality, and do not keep
  self-destructing content;
- do not use data from Telegram to train AI or machine-learning models;
- if your app shows channels, support sponsored messages as the terms require.

## License

Orbitext is free software licensed under the GNU General Public License v3.0 only (see [LICENSE](LICENSE)). Contributions require signing the CLA ([CLA.md](CLA.md)), which lets the maintainer also offer Orbitext under other terms, for example to ship it on the App Store. Third-party components keep their own licenses, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The Orbitext name and icon are not covered by the GPL, see [TRADEMARKS.md](TRADEMARKS.md).

Copyright (C) 2026 vsiioky.
