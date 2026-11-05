# Export Compliance

Date: 2026-11-05

A record of the encryption answers for App Store Connect and of the export
questions the open-source repository raises. It is not legal advice: the
points under "To confirm" are for the maintainer to settle before the first
public App Store submission.

## What the app contains

| Component | Cryptography | Purpose |
| --- | --- | --- |
| TDLib (MTProto 2.0) | AES-256-IGE, SHA-256, RSA-2048, Diffie-Hellman 2048 | transport encryption to Telegram servers; TDLib also implements secret chats |
| OpenSSL 3.4.0 (linked by TDLib) | TLS, AES, SHA, RSA, ECDH | the primitives MTProto uses, HTTPS fallback transports |
| SQLCipher (in TDLib) | AES-256 | encryption of the local TDLib database |
| Apple OS (URLSession, Keychain) | TLS, Keychain | system services, exempt on their own |

Orbitext's own Swift code implements no cryptography; it calls TDLib. All of
the above is standard, published cryptography used for data confidentiality
in a consumer messaging app.

## Why `ITSAppUsesNonExemptEncryption` is true

The key is false only when an app uses no encryption beyond the operating
system's or only encryption that is exempt outright (for example
authentication only). Orbitext ships its own copy of OpenSSL and uses it for
confidentiality, so the key is true (`project.yml`, OrbitextWatch info).
App Store Connect then asks the export compliance questions on each upload
until an export compliance code is assigned.

## Classification claimed

Mass market: ECCN 5A992.c (the app as distributed), eligible for License
Exception ENC under EAR 740.17(b)(1). The app is sold to the general public
through the App Store, the cryptography is not user-modifiable, it is
installed without substantial vendor support, and its function is described
publicly, which are the Note 3 to Category 5 Part 2 mass market criteria.

Expected App Store Connect answers:

1. Uses encryption: yes.
2. Qualifies for an exemption in Category 5 Part 2 (mass market): yes.
3. Proprietary or non-standard algorithms: no (see "To confirm" for MTProto).
4. Standard algorithms instead of, or in addition to, the OS's: yes.
5. Available in France: as decided below.

Since the March 2021 BIS rule, a 740.17(b)(1) end-user product like this one
needs no annual self-classification report; the report remains for
components, chips, toolkits and similar items, which the app is not.

## The open-source repository

The source code on GitHub is publicly available encryption source code under
EAR 742.15(b) and is not subject to the EAR. Since the March 2021 rule the
email notification to BIS and the NSA (crypt@bis.doc.gov, enc@nsa.gov) is
required only when the code implements "non-standard cryptography". The
repository implements none itself; it contains TDLib's generated API bindings
and links prebuilt TDLib and OpenSSL, both already public upstream.

## To confirm

- [ ] MTProto 2.0 is a Telegram-designed protocol built from standard
      primitives and published at core.telegram.org, but not adopted by a
      standards body. The EAR treats unpublished or unapproved protocols as
      non-standard; MTProto is published, so the answer to question 3 and
      the 742.15(b) notification is "no" on that reading. Confirm, or send the
      one-time notification email with the repository URL
      (https://github.com/vsiioky/orbitext) to be safe.
- [ ] France: distribution there of an app with non-exempt encryption needs
      an ANSSI declaration that App Store Connect asks to upload. Either file
      it or exclude France from the territories.
- [ ] Once App Store Connect assigns an export compliance code, add
      `ITSEncryptionExportComplianceCode` to the OrbitextWatch info in
      `project.yml` so uploads stop asking.
- [ ] Record the final answers in `app-store-checklist.md`.
