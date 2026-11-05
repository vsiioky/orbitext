# Generated TDLib bindings

This directory holds Swift bindings generated from TDLib's `td_api.tl`
schema by `scripts/codegen-tdlib.py`. The generated files are committed to
git so Xcode picks them up with zero CI overhead; `scripts/check-codegen.sh`
(run by `scripts/verify.sh` and CI) fails when they differ from what the
generator produces.

## What is here

- `TDLibSchema.swift` - typed model layer, namespaced under `enum TDApi`.
  Every generated TDLib constructor (e.g. `messageText`, `updateChatTitle`)
  is a `public struct TDApi.<UpperCamelName>`. Every abstract parent with
  more than one constructor in the schema (e.g. `MessageContent`, `Update`,
  `ChatType`) is a `public indirect enum` with one case per generated
  constructor plus `case unknown(tag: String)` for everything else.

- `TDLibDecoders.swift` - `TDApi.decode<TypeName>(_:)` for every struct and
  abstract enum. Decoders read `[String: Any]` dicts shaped like TDLib JSON
  (snake_case keys, `@type` discriminator, `int53/int64` accepted as both
  `Int`/`Int64`/`NSNumber` and `String`, `bytes` accepted as either `Foundation.Data`
  or base64 `String`). Missing object fields decode to `nil`, missing
  primitives default to `0`/`""`/`false`/empty `Data`/`[]`.

Both files start with a header naming the TDLib version and commit the
schema came from.

## Inputs

All under `scripts/`:

- `td_api.tl` - TDLib's `td/generate/scheme/td_api.tl`, copied verbatim from
  the TDLib commit the linked libraries are built from.
- `td_api.tl.source` - where that copy came from: TDLib version, commit and
  the sha256 of the file. The generator refuses a schema whose hash differs,
  so the vendored file cannot be edited by hand unnoticed.
- `codegen-roots.txt` - which types to generate (below).

The commit must be `TD_COMMIT` in `scripts/tdlib/build-all.sh`, the commit the
static libraries in `TDLib/` are built from. `scripts/check-codegen.sh`
compares the two, so the bindings cannot drift from the library again (they
once came from the 1.8.0 schema while the app linked 1.8.62 and 1.8.64).

## Which types are generated

The full schema has about 2000 constructors; the app decodes a few dozen
types. `codegen-roots.txt` lists the types the app uses (the roots), and the
generator emits those plus everything they reference through their fields.
Two refinements keep the closure small:

- `Class = ctor1 ctor2 ...` limits an abstract class to the listed
  constructors, wherever the class is reached from. Other constructors decode
  to `.unknown(tag:)`, which is how the app already treats everything it does
  not handle (`MessageContent`, `Update`, `InputMessageContent`).
- `skip ctor.field ...` leaves a field out of a struct, and with it the types
  only that field needs. Used for fields the app reads from the raw dict or
  never reads (`inlineKeyboardButtonTypeSwitchInline.target_chat`,
  `messageText.link_preview`).

To decode something new, add a root (or extend a `=` list, or drop a `skip`),
run `scripts/codegen.sh` and commit the result. Nothing else is needed: a
type that is not listed does not exist in `TDApi`, and a constructor that is
not listed arrives as `.unknown`.

## When TDLib is updated

1. Rebuild the libraries from the new commit (`scripts/tdlib/build-all.sh`,
   which pins `TD_COMMIT`).
2. Copy `td/generate/scheme/td_api.tl` of that checkout over
   `scripts/td_api.tl` and update `scripts/td_api.tl.source` (`version`,
   `commit`, and `sha256` from `shasum -a 256 scripts/td_api.tl`).
3. Run `scripts/codegen.sh`. It fails when a root, a listed constructor or a
   skipped field no longer exists in the schema.
4. Build. Exhaustive `switch`es over generated enums (text entity types, call
   discard reasons, chat actions) list the cases the new schema added; map
   them or fold them into the existing fallback. Memberwise initializers in
   tests change with the field lists, so build test data with `TDApi.decode*`
   from a dict instead.
5. Run `scripts/verify.sh`.

## How it stays reproducible

The generator uses the Python 3 standard library only, and its output depends
on nothing but its three inputs: declarations come out in schema order,
abstract enums sorted by name. Type names that would shadow a Swift type used
unqualified by the generated code (`String`, `Int32`, ...) or clash with each
other make generation fail. `bytes` fields are `Foundation.Data`, qualified
because the schema has a constructor named `data`, whose `TDApi.Data` would
otherwise shadow `Foundation.Data`.

## What is NOT here

- **Send-path types.** The `---functions---` section of `td_api.tl` is not
  generated. Requests are built as dicts by `TDLibService.send(...)` and
  friends.
- **Codable conformance.** Decoders take `[String: Any]` directly because
  that is what TDLib emits. No `JSONDecoder` round-trip.
- **Existing domain models stay.** `Orbitext/Models/MessageInfo`,
  `ChatInfo`, `MessageOrigin`, etc. are not replaced. The typed `TDApi`
  models are a *parsing intermediate*: mappings under
  `Orbitext/Telegram/Mappings/` convert them to the domain models.

## Migration status

Typed today: chats (with their last message and unread reaction count),
messages with all they carry (content, text and captions with spoiler, quote
and custom-emoji entities, reply with quote and origin, forward origin,
reactions, polls, sending state, bot keyboards), files, users (the transport
keeps a `UserInfo` per user), and the updates in `Mappings/Update+Mapping.swift`
(including `updateMessageInteractionInfo`).
`TDLibService.decodeMessageDict(_:)` is the one place a standalone message
dict becomes a `TDApi.Message`: `parseMessageInfo(_:)`, the `getMessage`
prefetch of replied messages and the send-completed updates all go through it,
and `MessageInfo(tdApi:service:)` maps the result. The one other decode site is
`TDApi.decodeChat`, which decodes a chat's `last_message` with the chat.
Nothing reads a member of a message from the raw dict. The fetched reply
target is cached as a `TDApi.Message` too.

Still read from raw dicts: responses and updates that do not build message or
user values (auth states, chat list pages, folders, file downloads, push
notification content), the dict update handlers in `TDLibService+Updates.swift`
that hand a nested message or chat to the typed mapping, and the bot mappings
of `userFullInfo`, `basicGroupFullInfo`, `supergroupFullInfo` and callback
answers (`Mappings/BotCommand+Mapping.swift`), whose types are not generated.

## License

The generated files are derived from TDLib's `td_api.tl` schema, which is
Copyright Aliaksei Levin (levlam@telegram.org), Arseny Smirnov
(arseny30@gmail.com) 2014-2026 and distributed under the Boost Software
License, Version 1.0 (`LICENSES/BSL-1.0.txt`). See `THIRD_PARTY_NOTICES.md`.
