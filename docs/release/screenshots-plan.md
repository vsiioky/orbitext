# Screenshot Capture Plan

## Data Safety

Screenshots must not show real private chats, real phone numbers, or real user identities.

Use a Telegram test account with demo chats, or verified mock data if a mock runtime is added later.

## Required Screens

- Auth method selection.
- Chat list with demo chats.
- Chat view with demo messages.
- Compose or voice recording screen.
- Settings with support/privacy entries.
- Widget unread count if App Store Connect screenshot slots allow it.

## Locales

Capture EN, RU, and KK screenshots if App Store Connect locale strategy requires localized screenshots. If one screenshot set is reused, record that choice in `docs/release/app-store-checklist.md`.

## Verification

Before upload, inspect each screenshot for:

- private data
- clipped text
- incorrect language
- misleading Telegram affiliation
- unreadable watchOS text
