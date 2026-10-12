# Privacy and local data

This document describes the source in this repository. A modified or separately distributed copy may behave differently; review the code and the operator’s disclosures before authorizing it.

## Google access

Float Tasks requests only `https://www.googleapis.com/auth/tasks.readonly`. It reads list identifiers and titles, plus active task identifiers, titles, notes, due dates, status, and parent relationships. Data supports the visible task list and local search. The app contains no task mutation endpoints.

Your default browser handles Google sign-in. The app does not receive your Google password. Authorization and token requests go directly to Google, and task requests go directly to `tasks.googleapis.com` over HTTPS. A temporary sign-in callback listens only on your Mac’s loopback interface.

The app checks for updates every 60 seconds while running; opening or manually refreshing the panel may trigger another request. It has no developer-operated server, telemetry, advertising, or AI integration. It does not sell task data, send it to advertisers, or use it to train models.

## Storage

| Data | Location and retention |
| --- | --- |
| Desktop OAuth client configuration and access/refresh tokens | macOS Keychain, under service `com.iuhachicha.floattasks.google`; configured as device-only, without iCloud Keychain synchronization. |
| Latest task snapshot and sync timestamps | `~/Library/Application Support/com.iuhachicha.floattasks/tasks.json`; replaced after a successful sync and kept for offline viewing. |
| Window geometry, opacity, pinning, and collapsed lists | Local macOS application preferences. |

The cache directory and snapshot use owner-only file permissions. The snapshot is JSON, not a separately encrypted database. Your Mac’s security and backup settings still apply. The original client JSON you downloaded is outside the app’s storage and remains under your control.

Starting a new sign-in clears the previous task view and snapshot before opening the browser. Importing a different Desktop client also clears the previous view. This prevents tasks from one account remaining visible after connecting another account whose first sync fails.

## Disconnecting and deleting data

Choose **Disconnect** in Settings to cancel syncing, remove saved sign-in tokens from Keychain, and delete the local task snapshot. The app retains the Desktop client configuration and display preferences for later use. It reports an error if local deletion fails.

Disconnect does not delete tasks from Google, revoke the authorization at Google, or remove copies in your backups. You can separately revoke access in your Google Account. Revocation blocks further access but does not itself erase the local snapshot; use Disconnect to clear it.

To remove the retained configuration, quit the app and delete the entries for `com.iuhachicha.floattasks.google` in Keychain Access. Do not share their contents in issues or support messages.

## Publishing a configured copy

If you distribute your own configured app, provide accurate privacy disclosures for its actual behavior and comply with the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including applicable Limited Use requirements. Do not treat this repository document as proof that Google has verified your app.
