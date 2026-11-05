# Security Policy

Orbitext is an unofficial Telegram client. It handles Telegram sessions,
message content and a TDLib database on the user's watch, so security reports
are taken seriously.

## Supported versions

Security fixes are made for:

| Version | Supported |
|---------|-----------|
| Latest TestFlight or App Store build | Yes |
| `main` branch | Yes |
| Older builds and other branches | No, please update first |

## Reporting a vulnerability

Please report vulnerabilities privately. Do not open a public issue, pull
request, or discussion for a security problem.

Use GitHub private vulnerability reporting:

https://github.com/vsiioky/orbitext/security/advisories/new

(Repository page -> Security tab -> "Report a vulnerability".)

A useful report contains:

- what is affected (component, file, or feature) and the app version or commit;
- steps to reproduce, or a proof of concept;
- the impact you expect (for example: session theft, message disclosure,
  remote code execution);
- your watch model and watchOS version, if the issue depends on them.

Please never include real session data, login codes, 2FA passwords, your
`api_hash`, or private chats in a report. Use a throwaway Telegram account
for testing, and redact logs before attaching them.

## What to expect

Orbitext is maintained on a best-effort basis by a single maintainer.

- You will get an acknowledgement within 7 days.
- You will get an assessment and a rough plan when the report is confirmed.
- Fixes ship in the next TestFlight or App Store build and on `main`. A
  security advisory is published after the fix is available. Reporters are
  credited if they wish.
- Please keep the report confidential until the fix is released. If you
  have not heard back after 7 days, you may send a short follow-up on the same
  advisory.

## Scope

In scope:

- the Orbitext watch app and its widget (`Orbitext/`, `OrbitextWidget/`,
  `OrbitextStub/`);
- the TDLib integration: how the app calls TDLib, handles its responses and
  manages the client lifecycle;
- local storage: the TDLib database and its encryption key (Keychain), caches,
  the shared App Group container, drafts, and voice-note files;
- push notifications and background refresh handling;
- the build and release scripts in `scripts/` and the CI configuration in
  `.github/`, where they could lead to a compromised build;
- the TDLib patches in `native-patches/` and the vendored code in `Packages/`.

Out of scope:

- vulnerabilities in Telegram's servers, protocol, or official apps. Report
  those to Telegram: https://telegram.org/faq#q-how-do-i-report-a-security-issue
  (Telegram also runs a bug bounty program);
- vulnerabilities in TDLib itself that do not depend on how Orbitext uses it.
  Report them upstream at https://github.com/tdlib/td. If you are unsure,
  report to Orbitext and the issue will be forwarded;
- issues that require a jailbroken or already compromised device or an
  unlocked watch in the attacker's hands, unless Orbitext makes the impact
  worse than the platform default;
- social engineering, spam, or denial of service against Telegram or any
  other third party;
- findings from automated scanners without a demonstrated impact.

## Safe harbor

Good-faith research that follows this policy, avoids other people's data, and
does not degrade Telegram's services is welcome, and the maintainer will not
take action against it.
