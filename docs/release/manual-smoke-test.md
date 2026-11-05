# Orbitext Manual Smoke Test

Date: 2026-05-15

Run this on Apple Watch hardware or a TestFlight installation when available.

## Setup

- [ ] Tester has a Telegram account available.
- [ ] Tester can access either QR login from another Telegram device or phone login with SMS/code.
- [ ] Tester has notifications enabled for Orbitext when testing push behavior.

## Auth

- [ ] First launch opens the auth flow.
- [ ] Language picker can select English.
- [ ] Language picker can select Russian.
- [ ] Language picker can select Kazakh.
- [ ] QR login starts and displays a QR code.
- [ ] Phone login accepts a country-code phone number.
- [ ] Code entry submits a valid code.
- [ ] 2FA password flow appears when account requires it.

## Core Messaging

- [ ] Chat list loads.
- [ ] Pagination loads more chats.
- [ ] Pinned chats render.
- [ ] Folder filter can be enabled and selected.
- [ ] Chat opens.
- [ ] New incoming message appears.
- [ ] Text message sends.
- [ ] Reply sends.
- [ ] Edit outgoing text works.
- [ ] Delete outgoing message works.
- [ ] Forward flow opens and sends.

## Media And Voice

- [ ] Voice recording starts.
- [ ] Voice recording cancels and removes temp file.
- [ ] Voice recording sends.
- [ ] Voice playback works.
- [ ] Photo preview opens.
- [ ] Video preview opens.
- [ ] Sticker renders.
- [ ] Document message renders.

## Notifications And Widget

- [ ] APNs registration succeeds in logs or no user-visible error appears.
- [ ] Incoming notification appears for a new message outside the active chat.
- [ ] Notification reply sends text.
- [ ] Mark-as-read action works.
- [ ] Widget shows unread count from App Group data.
- [ ] Widget updates after unread count changes.

## Settings And Logout

- [ ] Settings opens.
- [ ] Support/Report Problem opens a support route.
- [ ] Privacy Policy entry is visible after privacy task is complete.
- [ ] Cache size displays.
- [ ] Clear cache works.
- [ ] Logout asks for confirmation.
- [ ] Logout clears local session enough that the app returns to auth flow.
- [ ] Login works again after logout.
