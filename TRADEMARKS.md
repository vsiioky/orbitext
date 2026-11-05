# Orbitext Name and Icon Policy

The source code of Orbitext is licensed under the GNU General Public License,
version 3 only (GPL-3.0-only, see LICENSE). That license covers the code only. It does not grant any
right to use the "Orbitext" name, the Orbitext logo and app icon, or the app
identifiers. These remain the property of the maintainer (vsiioky).

## If you fork or redistribute Orbitext

You are free to fork the code, modify it and distribute your builds under the terms
of the GPL. If you do, your fork or build must:

1. Use a different name. Do not call it "Orbitext", and do not use a name that is
   confusingly similar.
2. Use a different app icon and logo. Do not ship the Orbitext icon or artwork.
3. Use your own bundle identifiers and app group. The identifiers `com.orbitext.*`
   and `group.com.orbitext.shared` are reserved for the official app.
4. Use your own Telegram `api_id` and `api_hash`, obtained at
   https://my.telegram.org. The Telegram API Terms of Service (section 2.1)
   require every app to have its own. The official credentials are never part of
   this repository.
5. Use your own support and privacy contacts. The support Telegram handle and the
   privacy policy URL are defined in `Orbitext/App/AppConstants.swift`, and the
   in-app policy text in `Orbitext/Views/Settings/PrivacyPolicyView.swift` names
   the same contact; replace them with ones you operate. Do not point users of your build to the official support
   channel or privacy policy.
6. Make clear that your build is not the official Orbitext app.

No exception to the GPL is granted for distribution through the App Store or any
other store. Anyone who distributes a build must comply with the GPL and with the
store's own terms, and must do so under their own name, icon and identifiers.

## What is fine without asking

- Nominative use, for example "based on Orbitext" or "a fork of Orbitext", to
  describe where your work comes from, as long as it does not suggest endorsement.
- Referring to Orbitext in documentation, articles, reviews and issue reports.
- Building the app from source for your own use or for development and testing.
- Contributing changes back through pull requests (see CLA.md).

## Telegram

"Telegram" is a trademark of Telegram FZ-LLC. Orbitext is an unofficial Telegram
client. It uses the Telegram API and is part of the Telegram ecosystem, but it is
not affiliated with, endorsed by or sponsored by Telegram. Forks must keep this
statement visible and must follow the Telegram API Terms of Service
(https://core.telegram.org/api/terms), including the rules on app naming (the name
must not contain "Telegram" unless preceded by "Unofficial") and on the Telegram
logo (the official logo must not be used).

## Questions

If you want to use the Orbitext name or icon in a way not covered above, ask first.
Open an issue on https://github.com/vsiioky/orbitext or contact the maintainer
through the support channel listed in the app.
