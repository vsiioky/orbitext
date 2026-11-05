# App Store Submission Checklist

## App Information

- [ ] App name is available: Orbitext.
- [x] Bundle ID is `com.orbitext.app`.
- [ ] SKU is selected.
- [ ] Primary category is selected.
- [ ] Age rating questionnaire is completed.

## Metadata

- [x] English metadata is drafted.
- [x] Russian metadata is drafted.
- [x] Kazakh metadata is drafted.
- [x] Field lengths fit App Store Connect (name 30, subtitle 30, promo 170, keywords 100): `scripts/release/check-metadata-lengths.sh` passes.
- [ ] English metadata is entered in App Store Connect.
- [ ] Russian metadata is entered in App Store Connect.
- [ ] Kazakh metadata is entered in App Store Connect.
- [ ] Support URL is live.
- [ ] Privacy Policy URL is live.

## Privacy And Compliance

- [ ] App Privacy answers are completed in App Store Connect.
- [x] Privacy policy is linked in metadata drafts.
- [x] Privacy policy is accessible in the app via Settings.
- [ ] Export compliance answer is recorded (see `export-compliance.md`).
- [x] Telegram non-affiliation wording is present in metadata drafts and reviewer notes.
- [x] Name, subtitle and keywords contain no Telegram trademark and keywords carry no Apple one (the subtitle says "for Apple Watch" to state compatibility); the description names Telegram only to state compatibility, with a non-affiliation disclaimer.

## Screenshots

- [ ] Screenshots use test/demo data only.
- [ ] Login screenshot is captured.
- [ ] Chat list screenshot is captured.
- [ ] Chat view screenshot is captured.
- [ ] Compose or voice screenshot is captured.
- [ ] Settings or widget screenshot is captured.

## Reviewer Notes

- [x] Login methods are documented.
- [x] Capabilities are documented.
- [ ] Reviewer test account is provided, or release owner confirms none will be provided.

## Final Gate

- [x] No local P0/P1 issues are known after Phase 1 verification.
- [x] Final local identifier, localization, unit test, and archive checks pass.
- [ ] Final archive uploaded.
- [ ] Reviewer notes entered.
- [ ] Build submitted for review.
