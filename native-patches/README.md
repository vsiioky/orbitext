# TDLib invalidated push token retry

The pinned TDLib source restores a saved nonempty push token as Reregister on
startup. Its on_result handler retries every error in that state; a terminal
400 TOKEN_WAS_INVALIDATED therefore schedules another attempt after one second.

tdlib-token-invalidated.patch changes only that exact error in Reregister:
report the original error to any pending caller, set that token slot to Sync
with an empty token, and call the existing save_info boundary. That boundary
erases only the device_tokenN entry. No unregister request is sent by this branch.
Authorization, database encryption keys, messages, and other token slots are
unaffected. Temporary errors, FLOOD_WAIT delays, new Register requests, and
Unregister requests retain their existing behavior. The existing query-id check
rejects late failures from a replaced token before the new branch.

This stops retries of the rejected stored token. It does not establish why the
server rejected it or prove that push delivery is restored. A same-token
registerDevice call can already have returned a cached pushReceiverId while
native Reregister was pending, so Swift acceptance is not a fresh server
acknowledgement. A later fresh token or application restart can initiate another
registration normally.

Telegram's first-party iOS client also treats TOKEN_WAS_INVALIDATED separately:
https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/TelegramCore/Sources/TelegramEngine/AccountData/RegisterNotificationToken.swift

## Offline regression

The commands below use these placeholders: `TDLIB_SRC` (a TDLib checkout at
the pinned commit), `TDLIB_SRC_ARM64_32` and `TDLIB_BUILD_ARM64_32` (the
arm64_32 source and build trees), `OPENSSL_ARM64_32` (OpenSSL built for
arm64_32).

From the project root, using a NEW output path:

    /usr/bin/python3 -B scripts/tdlib/test-device-token-manager.py \
      --source "$TDLIB_SRC/td/telegram/DeviceTokenManager.cpp" \
      --output /tmp/orbitext-native-token-regression

The runner verifies the original source hash, applies the patch to a copy, and
compiles the complete on_result function verbatim into the same offline boundary
harness for both versions. The baseline must fail exactly the two invalidation
cases; the patched version must pass all 11 cases. Query, Global, promise, timer,
and persistence boundaries are fakes: no TDLib client, network, Keychain, or
application database is opened. This verifies the actual transition and call to
persistence, not a real binlog or APNs delivery.

## Isolated three-slice rebuild

    /usr/bin/python3 -B scripts/tdlib/rebuild-device-token-manager.py \
      --source-arm64 "$TDLIB_SRC" \
      --source-arm64-32 "$TDLIB_SRC_ARM64_32" \
      --build-device-arm64 "$TDLIB_SRC/build-watchos" \
      --build-device-arm64-32 "$TDLIB_BUILD_ARM64_32" \
      --build-simulator "$TDLIB_SRC/build-watchsim" \
      --libraries "$PWD/TDLib" \
      --output /tmp/orbitext-native-token-libraries

The original native source and archives are read-only inputs. The script:

- Requires the two inspected native commits and identical pinned source hashes.
- Verifies the actual app archive's DeviceTokenManager object against its build
  object. Simulator arm64 matches exactly; device arm64_32 has four archive
  alignment bytes. The exact pinned device arm64 object had a historical relink:
  all five code/data sections, 1,302 resolved relocations, and 235 external
  bindings match after local-symbol and defined-weak-reference normalization.
  Only that pinned pair of hashes may use this normalization.
- Compiles only DeviceTokenManager.cpp using each slice's existing include paths
  and flags, replacing the unavailable SDK path with the selected Xcode SDK.
  Original deployment minima are preserved: simulator arm64 10.0, device arm64
  26.0, device arm64_32 26.5.
- Replaces exactly one object in each copied core archive and verifies every
  other member's bytes. Other libraries are copied unchanged. The two device
  slices are assembled into a new universal archive.
- Rechecks all original archive hashes and writes manifest.json with source,
  compiler, command, object, and output hashes.

The output contains complete lib-device and lib-simulator directories. The
script does not install or swap them. Review the output, then run the watch
tests and app/container link checks before installing it. Physical and
simulator runtime validation remain separate from these offline and compile
checks.

## Correct the existing arm64_32 deployment minimum

The initial generic watchOS link exposed 503 warnings across 12 native
arm64_32 libraries: the app targets 26.0, while these objects declare 26.5.
502 warned objects were byte-identical to the original baseline; the changed
DeviceTokenManager object also retained its original 26.5 minimum. This is a
pre-existing build configuration mismatch, beyond the one-object push fix.

The pinned CMake/iOS.cmake forcibly clears CMAKE_OSX_DEPLOYMENT_TARGET. The old
build also left IOS_DEPLOYMENT_TARGET and C/CXX minimum flags empty, so its
SDK 26.5 supplied the minimum. The full rebuild recipe sets both
IOS_DEPLOYMENT_TARGET=26.0 and explicit -mwatchos-version-min=26.0 in the C and
C++ flags. It preserves the app minimum and all supported architectures.

Use a NEW directory under /tmp:

    /usr/bin/python3 -B scripts/tdlib/rebuild-watchos26-arm64-32.py \
      --source "$TDLIB_SRC_ARM64_32" \
      --openssl "$OPENSSL_ARM64_32" \
      --libraries "$PWD/TDLib" \
      --output /tmp/orbitext-native-watchos26-rebuild \
      --jobs 6
    /usr/bin/python3 -B scripts/tdlib/verify-watchos26-arm64-32.py \
      --build-root /tmp/orbitext-native-watchos26-rebuild

The builder copies the pinned arm64_32 source commit and generated schemas,
retains its git version metadata, copies OpenSSL, and applies only the approved
token patch. It verifies all compilation commands use arm64_32/26.0 and copied
inputs, then builds the existing Release/O3 tdjson_static target and dependencies.
The verifier checks every native member's architecture/platform/minimum, keeps
the existing arm64 device slice byte-identical, and copies simulator/OpenSSL
archives unchanged. No original source/build directory or project archive is
modified; no install or library swap is performed. Full input/command/object
counts and output hashes are recorded beside the build.

The first isolated execution completed in 145.2 seconds: all 538 members in 12
TDLib archives declared watchOS 26.0, with one upstream SQLite warning that
gethostuuid() is disabled and no compile errors. This full recipe supersedes the
old arm64_32 baseline used by the one-object rebuild above; that earlier script
intentionally rejects unreviewed archive/object drift.

Before using the proposed-libraries directories, independently review their
manifest and run the generic watchOS link to confirm the 26.5-to-26.0 warnings
are gone. A corrected deployment declaration is not runtime validation on older
watchOS or an App Store acceptance result.

# TDLib HTTP transport memory on watchOS

watchOS has no raw sockets for this app, so TDLib sends MTProto over HTTP
through NSURLSession (`tdnet/td/net/DarwinHttp.mm`, used by
`RawConnectionHttp` when `TD_DARWIN_WATCH_OS`). Two leaks in that file grew
with every request, so with network traffic and even while idle (TDLib keeps
long-polling):

- `DarwinHttp::get`/`post` run on TDLib's own threads, which have no
  autorelease pool. NSURL, the request, its body, the data task and
  CFNetwork's CFHTTPMessage objects went into the thread's implicit pool and
  stayed for the life of the thread. In the simulator, an idle app gained
  about 800 CFHTTPMessage objects, 90 data tasks and 1 MB per 90 seconds.
  Fix: an `@autoreleasepool` around building and resuming the request.
- The completion handler runs on a URL session pool thread. `BufferSlice(Slice)`
  of a reply under 512 bytes takes a per-thread 16 KB batch buffer, which
  TDLib frees only on threads it started (`clear_thread_locals`). Every pool
  thread GCD retired leaked 20 KB (`leaks` reports them as ROOT LEAKs under
  `do_init_thread_local<BufferRawTls>`). Fix: copy the reply through a
  `BufferWriter`, which owns its buffer.

`tdlib-darwin-http-memory.patch` makes only these two changes. The request,
headers, timeouts, status handling and error path are unchanged.

The app side keeps the same rule for its own calls: every td_send, td_execute
and td_create_client_id runs on `TDNativeCallThread`, td_receive on the
receive loop's thread, so TDLib never allocates per-thread buffers on a
thread that later exits.

## Archive check

scripts/tdlib/verify-libs.sh (run by scripts/verify.sh, CI and --update)
checks, beside the pinned hashes, that for every slice of
TDLib/lib-device/libtdnet.a (arm64, arm64_32) and
TDLib/lib-simulator/libtdnet.a (arm64) the DarwinHttp.mm.o member imports
_objc_autoreleasePoolPush. Other members of the archive import it for
unrelated reasons, so the symbol is read from that member only. The
patched objects import it; the archives built before
tdlib-darwin-http-memory.patch do not, and the check fails on all three
of their slices. To run it on other archives:

    scripts/tdlib/verify-libs.sh --http-patch path/to/libtdnet.a ...

## Known and bounded: an abandoned HTTP task is not cancelled

Not fixed, and TDLib is left as it is. When TDLib drops a connection
(ping timeout, network change), `RawConnectionHttp::close` only logs, and
`DarwinHttp::http_send` does not keep the NSURLSessionDataTask it resumes,
so nothing can cancel it. The task runs on in the shared session until it
completes or reaches the 90 s resource timeout (the session also sets
waitsForConnectivity, so offline it waits instead of failing). Each such
task holds its request, body copy, completion block, the connection's answer
queue and that queue's two descriptors.

The cost is bounded and gives itself back: while the app is in the
foreground and offline, abandoned tasks accumulate up to the 90 s window,
estimated at 25-30 tasks per active client (about 0.1-0.5 MB and 50-60
file descriptors), and drain within about 25 s of the network coming back.
It is not the per-request leak that tdlib-darwin-http-memory.patch removed: the objects are released
when the task finishes. Estimated from the source, not measured.

A fix would keep the task in each RawConnectionHttp and cancel it in
`close()` and the destructor, and possibly drop waitsForConnectivity or
shorten the resource timeout so that TDLib's reconnect logic is the only
retry loop. That is a second native patch and a rebuild of every slice, and
changes when a slow request is given up, so it waits for a measurement
(simulator `heap <pid>` and `lsof -p <pid> | wc -l` every 30 s through 5
minutes of 100% packet loss) that shows it matters.
