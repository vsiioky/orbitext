# Orbitext Privacy Data Map

Date: 2026-05-15

This document is a factual map for App Store privacy answers and privacy policy drafting. It is not legal advice.

## App Model

Orbitext is an independent standalone Apple Watch Telegram client. It uses Telegram TDLib/MTProto to connect to Telegram. No developer-operated backend is confirmed in the local project.

## Data Processed By The App

| Data | Source | Local Storage | Shared With Developer Backend | Shared With Telegram |
| --- | --- | --- | --- | --- |
| Telegram account auth state | Telegram login through TDLib | TDLib database | No backend confirmed | Yes |
| Phone number during login | User input / Telegram auth | TDLib/auth flow | No backend confirmed | Yes |
| Chats and messages | Telegram via TDLib | TDLib database, chat/message caches | No backend confirmed | Yes |
| Contacts | Telegram via TDLib | contact cache/list cache | No backend confirmed | Yes |
| Media files | Telegram via TDLib | disk cache and image cache | No backend confirmed | Yes |
| Voice recordings | User microphone | temporary recordings before send, sent media cache | No backend confirmed | Yes when sent |
| Drafts | User input | `drafts.json` and Telegram draft sync | No backend confirmed | Yes when synced |
| Pending messages | User input | `pending_messages.json` | No backend confirmed | Yes when sent |
| Notification data | Telegram/APNs/TDLib | delivered notifications, notification keys | No backend confirmed | Yes |
| Widget unread data | App state | App Group UserDefaults | No backend confirmed | No direct backend confirmed |
| Diagnostics/logs | OSLog/local runtime | device logs | No backend confirmed | No direct backend confirmed |

## Local Data Deletion

Logout is expected to clear local app-owned session data, drafts, queues, caches, voice recordings, and TDLib local database. This must be verified by the manual smoke test.

## App Store Connect Privacy Answer Notes

Do not answer "Data Not Collected" unless the release owner confirms Apple's definition allows the app's local/Telegram-only processing to be represented that way. The app processes user content, contacts, identifiers, and audio/media in order to provide Telegram client functionality.

## Privacy Manifest Notes

`Orbitext/App/PrivacyInfo.xcprivacy` currently declares no tracking, no tracking domains, no collected data types, and no accessed API categories. The release archive on 2026-05-15 did not emit a blocking privacy manifest warning.

If Apple/Xcode later emits warnings about required accessed API categories, add only the specific categories named by Xcode and document the reason here.

## Open Release Owner Decisions

- Final App Store privacy answers.
- Privacy Policy URL.
- Whether any developer-operated analytics, crash reporting, or backend service will be added.
- Export compliance/encryption answers.
