# Privacy and local data

This document describes the source in this repository. A modified or separately distributed copy may behave differently; review the code and the operator’s disclosures before authorizing it.

## Google access

New sign-ins request `https://www.googleapis.com/auth/tasks` so Float Tasks can view, create, edit, complete, reopen, and delete tasks. Existing `tasks.readonly` sign-ins remain usable for viewing until you choose **Enable editing** and authorize the write permission. Google grants the Tasks scope for the account as a whole; it cannot be restricted to a single list. The app checks that each mutation targets a currently visible list and, when applicable, a task belonging to that list.

The app reads all returned list identifiers and titles, plus active and completed task identifiers, titles, notes, due dates, status, and parent relationships. Completed tasks marked hidden by Google are included so they can be reopened. Selected list IDs control display and write targets, not which lists are fetched or cached. The header and status counts show remaining tasks.

Task content is used to display your lists, search locally, and perform the edits you request. Creating or changing a task sends the relevant content to Google; deletion sends its identifiers. A confirmed deletion of an assigned task also deletes its original task in Docs or Chat, according to [Google's deletion behavior](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/delete).

Your default browser handles Google sign-in. The app does not receive your Google password. Authorization and token requests go directly to Google, and task requests go directly to `tasks.googleapis.com` over HTTPS. A temporary sign-in callback listens only on your Mac’s loopback interface.

The app checks for updates every 60 seconds while running; opening or manually refreshing the panel may trigger another request. It has no developer-operated server, telemetry, advertising, or AI integration. It does not sell task data, send it to advertisers, or use it to train models.

## Storage

| Data | Location and retention |
| --- | --- |
| Desktop OAuth client configuration, access/refresh tokens, and granted scopes | macOS Keychain, under service `com.iuhachicha.floattasks.google`; configured as device-only, without iCloud Keychain synchronization. |
| Latest snapshot of all fetched lists and active/completed tasks, plus sync timestamps | `~/Library/Application Support/com.iuhachicha.floattasks/tasks.json`; updated after successful reads or writes and kept for offline viewing. |
| Window geometry, opacity, pinning, collapsed lists, and selected list IDs | Local macOS application preferences. |

The cache directory and snapshot use owner-only file permissions. The snapshot is JSON, not a separately encrypted database. Your Mac’s security and backup settings still apply. The original client JSON you downloaded is outside the app’s storage and remains under your control.

Starting a new sign-in clears the previous task view and snapshot before opening the browser. An **Enable editing** upgrade does the same while preserving the selected list IDs. Importing a different Desktop client also clears the previous view. This prevents tasks from one account remaining visible after connecting another account whose first sync fails.

Editor drafts stay in the app's memory until saved or dismissed; they are not a separate persistent offline queue. The app does not automatically retry writes. If it cannot determine whether Google accepted a change, it asks you to refresh before retrying.

## Disconnecting and deleting data

Choose **Disconnect** in Settings to cancel syncing, remove saved sign-in tokens from Keychain, delete the local task snapshot, and reset the list selection. The app retains the Desktop client configuration and other display preferences for later use. It reports an error if local deletion fails.

Disconnect does not delete tasks from Google, revoke the authorization at Google, or remove copies in your backups. You can separately revoke access in your Google Account. Revocation blocks further access but does not itself erase the local snapshot; use Disconnect to clear it.

To remove the retained configuration, quit the app and delete the entries for `com.iuhachicha.floattasks.google` in Keychain Access. Do not share their contents in issues or support messages.

## Publishing a configured copy

If you distribute your own configured app, provide accurate privacy disclosures for its actual behavior and comply with the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including applicable Limited Use requirements. Do not treat this repository document as proof that Google has verified your app.
