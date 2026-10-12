# Tests

Run `./tests/run.sh` from the repository root on macOS 13 or later with Xcode Command Line Tools that include Swift 6 installed. It works on Apple silicon and Intel Macs and downloads no dependencies.

The suite uses synthetic fixtures. It never opens a browser, accesses the real Keychain, loads the app's saved tasks, or contacts Google. The callback integration test opens a temporary listener bound only to `127.0.0.1` and connects to that listener through a cookie-free ephemeral session.

- **OAuth security:** the RFC 7636 PKCE vector, random state, Desktop client validation, form encoding, callback path/host/state checks, duplicate parameter rejection, permission checks, IPv4 loopback binding, invalid-request recovery, one-time consumption, and cancellation.
- **Persistent sign-in:** restoration after relaunch, silent refresh after access-token expiry, concurrent refresh, refresh-token retention and rotation, offline retry, revoked authorization, and explicit sign-out.
- **Tasks API client:** complete pagination, API order and metadata, empty lists, task filtering, encoded identifiers and page tokens, duplicate IDs, malformed responses, scoped errors, origin checks, and cancellation.
- **Account-switch privacy:** clearing the previous account before authorization, retaining that protection when the new account's first sync fails, rejecting late responses after account changes or disconnect, clearing the cache on client changes, and blocking authorization when the previous cache cannot be deleted. The permission-denial case is skipped if the tests run as root.

`PrepareOAuthFixture.swift` creates a temporary copy of the current OAuth source with its Keychain and token transport declarations replaced by `OAuthTestDoubles.swift`. Browser opening is replaced by a trap that fails the test. The generator checks each replacement boundary and refuses to proceed when a boundary changes or a known side-effect operation remains. Production source is never modified; no generated source or executable is kept in the repository. The API tests compile the real API client with its injected transport and a synthetic OAuth stub. The privacy tests compile the actual Store and Models with authentication/API doubles and point `FLOATTASKS_DATA_DIR` at a temporary directory, which is deleted when the script exits.

These tests verify app logic and the local callback server. They do not prove that a particular Google Cloud project is configured correctly, that a real account grants consent, or that macOS permits a particular signed app to access its Keychain items.

## Optional native scroll layout test

Run `./tests/run-scroll.sh` in a logged-in macOS desktop session. It is separate from `run.sh` and is not intended for headless CI.

The test compiles the actual `FloatingUI.swift` and `Models.swift` with a synthetic `TaskStore`. It lays out an off-screen AppKit panel with 24 lists and 501 tasks, then sends 96 alternating top/bottom requests through SwiftUI's `ScrollViewReader` while resizing between 240, 250, 280, and 460 points. It reads the underlying `NSScrollView` geometry to check that the requested boundaries are reached. A background watchdog fails the process if main-loop progress stops for more than eight seconds. Expect about 20 seconds of runtime after compilation.

No Google account, Keychain, saved task cache, network access, Accessibility permission, or injected system input events are used. The test does not activate its window. Its temporary executable is removed on exit, and its single test-specific preferences value is removed on normal completion.

This checks responsive layout and stable scroll targeting with varied card heights. It is not a deterministic reproduction of every OS-specific scroll hang, and it does not exercise the production app delegate or real trackpad momentum. Also manually check scrolling to the bottom, continuing to scroll there, scrolling back up, and resizing the installed app.
