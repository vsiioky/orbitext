# Contributing to Orbitext

Thank you for your interest in Orbitext, an unofficial Telegram client for
Apple Watch. Bug reports, translations, tests, documentation, and code are all
welcome.

By participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
Security problems go through [SECURITY.md](SECURITY.md), never through public
issues.

## Start with an issue

- Small fixes (typos, an obvious bug, a missing translation) can go straight to
  a pull request.
- For anything larger, a new feature, a refactor, or a change that touches
  `ChatRepository`, `ChatView`, or the TDLib layer, open an issue first and
  agree on the approach. This avoids work that cannot be merged and avoids two
  people changing the same subsystem at once.
- Search existing issues before opening a new one. Issues labelled
  `good first issue` and `help wanted` are a good place to start.
- Bug reports: include the watch model, the watchOS version, the Orbitext
  version and build (TestFlight build number if you have one), what you did,
  what you expected, and what happened. Remove phone numbers, names, message
  text, and anything else private from logs and screenshots.

## Contributor License Agreement (CLA)

Every contributor must sign the [CLA](CLA.md) before a pull request can be
merged. The CLA lets the maintainer distribute Orbitext under other terms as
well as the GPL (for example on the App Store), while you keep the copyright
to your own contribution.

When you open your first pull request, the CLA bot comments on it. To sign,
reply on the pull request with exactly this sentence:

```
I have read the CLA Document and I hereby sign the CLA
```

The signature is recorded once and covers your later contributions. Do not
submit code you do not have the right to contribute: it must be your own work,
or work whose license allows this, and if you write code for an employer, make
sure they permit the contribution.

## Development setup

Follow [Build from source](README.md#build-from-source) in the README: install
the tools, get the TDLib libraries, add your own Telegram API credentials, and
generate or open the Xcode project.

Then, once per clone, enable the repository hooks:

```bash
git config core.hooksPath .githooks
```

The simulator is the supported path for contributors. Unit tests run on a
watchOS simulator and do not need Telegram credentials or a signing team.
Device builds, push notifications, and TestFlight use identifiers owned by the
maintainer (`com.orbitext.*`, `group.com.orbitext.shared`). If you want to run
your own build on a watch, set your own team in `Signing.local.xcconfig`, use
your own bundle identifiers, and see the Telegram API rules below. Do not
commit those changes.

## Checks before you push

`scripts/verify.sh` is the gate for every change that touches code. CI runs
the same checks. It covers:

- TDLib archive hashes (`scripts/tdlib/libs.sha256`);
- `Orbitext.xcodeproj` is in sync with `project.yml`;
- release checks, including localization keys;
- banned APIs and the transport boundary (see Code rules below);
- generated TDLib bindings (`scripts/check-codegen.sh`; regenerate with
  `scripts/codegen.sh` after changing the schema);
- SwiftFormat lint;
- unit tests with a coverage summary, and a build of the UI test target;
- Swift 6 concurrency diagnostics in app code.

```bash
scripts/verify.sh              # everything
scripts/verify.sh --no-tests   # static checks and a build only
scripts/verify.sh --tsan       # unit tests under Thread Sanitizer
```

Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if your Xcode
is installed elsewhere or `xcode-select` points at a beta: the test runner
hangs under the Xcode 27.0 beta, so use Xcode 27.1. The tested tool versions
are listed in the README. A different SwiftFormat or XcodeGen version can
produce false failures.

If a check fails, fix the cause. Do not silence a diagnostic, delete a
baseline entry, or edit a check to make it pass without explaining why in the
pull request.

## Code rules

- **Swift 6.** Every target builds in the Swift 6 language mode, and a data
  race the compiler can see is an error. Do not enable Approachable
  Concurrency, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`,
  or default main-actor isolation: they would move TDLib response parsing onto
  the main actor. Do not use `@unchecked Sendable` or `nonisolated(unsafe)`
  to get around a diagnostic: prefer real `Sendable` types and protect shared
  mutable state with a `Mutex` or an actor. If an escape hatch is unavoidable
  (for example around a C API), keep it small and explain it in a comment. The
  reasoning is in the comments in `project.yml`.
- **Transport boundary.** App code outside `Orbitext/Telegram/` talks to
  Telegram only through `TelegramServiceProtocol` and the capability
  protocols in `TelegramServiceCapabilities.swift`. `scripts/verify.sh` fails
  when other code names `TDLibService`, `TDJsonWrapper`, or
  `TDClientLifecycleGate`. The test double lives in `OrbitextTests`, not in
  the app target.
- **Generated code.** Do not edit `Orbitext/Telegram/Generated`; it comes from
  `scripts/codegen.sh`.
- **No private data in logs.** Message and quote text must never reach the
  system log.
- **Watch UI.** Use the WatchKit inline movie player for video, not SwiftUI
  `VideoPlayer`. Do not call `UserDefaults.synchronize()`.
- **Style.** Formatting comes from [`.swiftformat`](.swiftformat). Run
  `swiftformat Orbitext OrbitextWidget OrbitextTests OrbitextUITests OrbitextStub`
  before committing; `swiftformat --lint` on the same paths is what the gate
  runs. Prefer small focused files, early returns, and immutable values.
- **Project file.** Never edit `Orbitext.xcodeproj/project.pbxproj` by hand.
  After adding, removing, or renaming a file (tests included), or editing
  `project.yml`, run `xcodegen generate` and commit the result. After a
  rebase, regenerate instead of merging the project file by hand.

## Tests

- A change in behavior needs a test. Bug fixes should come with a test that
  fails without the fix.
- Tests use the scripted transport and the mock Telegram service in
  `OrbitextTests`; they do not talk to the network or need credentials.
- Run the full unit-test suite through `scripts/verify.sh`. A pull request that
  lowers coverage of the code it changes needs a reason.
- Changes you cannot test automatically (for example push or device-only
  behavior) should say in the pull request how you checked them.

## Localization

Orbitext ships in English, Russian, and Kazakh. English is the base language.

- Add every new user-visible string to all three files:
  `Orbitext/Resources/en.lproj/Localizable.strings`,
  `Orbitext/Resources/ru.lproj/Localizable.strings`, and
  `Orbitext/Resources/kk.lproj/Localizable.strings`. The key sets must match.
- Do not hard-code user-facing text in views. Use `L10n.string(...)` or
  `String(localized:)`.
- Check your change with `scripts/release/check-localization-keys.sh` (also
  part of `scripts/verify.sh`). `scripts/release/list-hardcoded-ui-strings.sh`
  finds strings that bypass localization.
- Translation fixes are welcome as plain pull requests. If you would like to
  add a new language, open an issue first.

## Telegram API rules

Orbitext uses the Telegram API and must follow the
[Telegram API Terms of Service](https://core.telegram.org/api/terms). A change
that breaks them cannot be merged. In particular, do not add:

- ghost mode or hiding of read receipts, faked online or typing status, or any
  other way of interfering with Telegram's core functionality;
- storing, saving, or forwarding self-destructing content in ways Telegram
  does not allow;
- any use of Telegram data to train AI or machine-learning models;
- the official Telegram logo or branding. The name "Telegram" may appear only
  to describe compatibility, and Orbitext always presents itself as
  unofficial;
- a shared or hard-coded `api_id`. Every build uses the credentials of the
  person building it.

## Secrets and personal data

Never commit or paste into issues, pull requests, screenshots, or logs:

- `api_id` and `api_hash` (they belong in the gitignored
  `Orbitext.local.xcconfig`);
- Apple team IDs, certificates, provisioning profiles, or API keys
  (`Signing.local.xcconfig` and `ExportOptions.plist` are gitignored);
- Telegram session data, login codes, 2FA passwords, or the TDLib database;
- real chats, phone numbers, names, or other personal data. Use test accounts
  and invented text in fixtures and screenshots.

Do not commit editor, OS, or local tool state. Use a global gitignore for
those.

## Commits and history

- Commit messages follow Conventional Commits:
  `type(optional-scope): short imperative subject`, with `type` one of `feat`,
  `fix`, `perf`, `refactor`, `test`, `docs`, `style`, `build`, `ci`, `chore`,
  `revert`. Example: `fix: retry removing the old voice-uploads folder`.
  The `commit-msg` hook (enabled by the command above) rejects other subjects.
- Explain why in the message body when it is not obvious from the diff.
- Keep commits focused. Do not mix a refactor with a behavior change.
- No checkpoint or WIP commits on `main`: squash them on your branch first.
- Pull requests are squash-merged, so the pull request title is the final
  commit subject and must follow the same format.
- Do not rewrite history on a branch other people are using.

## Pull request checklist

Before you request a review:

- [ ] The change is linked to an issue, or is small and self-explanatory.
- [ ] `scripts/verify.sh` passes, and the pull request says so.
- [ ] Tests cover the new or changed behavior.
- [ ] `xcodegen generate` was run if files or `project.yml` changed, and
      `project.pbxproj` was not edited by hand.
- [ ] New strings exist in `en`, `ru`, and `kk`, and
      `scripts/release/check-localization-keys.sh` passes.
- [ ] The change follows the Telegram API rules above.
- [ ] No secrets, team IDs, personal data, or unrelated files are included.
- [ ] Screenshots or simulator notes are attached for UI changes (with no real
      chats visible).
- [ ] You have signed the CLA.

## License

Orbitext is licensed under the GNU General Public License v3.0 only. By
contributing and signing the CLA, you agree that your contribution can be
distributed under the GPL and, as described in the CLA, under other terms
chosen by the maintainer. See [LICENSE](LICENSE), [CLA.md](CLA.md), and
[TRADEMARKS.md](TRADEMARKS.md).
