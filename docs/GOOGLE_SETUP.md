# Google setup

Float Tasks uses the official Google Tasks API and your own Google Desktop OAuth client. Configuration and sign-in take place locally; this repository does not provide credentials or a hosted authentication service.

Google’s console and requirements can change. The links below point to the official instructions checked when this guide was written.

## 1. Create and configure a project

1. Open [Google Cloud Console](https://console.cloud.google.com/) and create or select a project you control.
2. In **APIs & Services → Library**, enable **Google Tasks API**.
3. Open **Google Auth Platform** and complete the app’s branding, support contact, and audience details. Use your own accurate information.
4. For an external app in **Testing**, add the Google account you will use under **Audience → Test users**.
5. Under **Data Access**, configure the Google Tasks scope: `https://www.googleapis.com/auth/tasks`. This permits viewing, creating, editing, and deleting tasks. Keep `tasks.readonly` configured if you also support existing read-only users.

See Google’s [Tasks API authorization guide](https://developers.google.com/workspace/tasks/auth) and [OAuth branding requirements](https://support.google.com/cloud/answer/15549049).

## 2. Create a Desktop OAuth client

In **Google Auth Platform → Clients**, create an OAuth client with application type **Desktop app**. Download its JSON file and keep it outside your source checkout.

Do not choose Web application or Service account. Float Tasks uses your system browser, PKCE, and a temporary callback at `127.0.0.1` on an available local port. It does not require a hosted redirect endpoint or a browser extension. Google documents this flow in [OAuth 2.0 for desktop apps](https://developers.google.com/identity/protocols/oauth2/native-app).

## 3. Import and sign in

1. Run Float Tasks and open **Settings…** from the menu-bar icon’s right-click menu.
2. Choose **Import Google client JSON…** and select the downloaded file.
3. Choose **Sign in with Google**. Confirm the selected account and the Google Tasks permission request.
4. Return to Float Tasks after the browser completes the sign-in. Open the panel to see your lists.

The app stores the imported client configuration, tokens, and granted scopes in macOS Keychain. You do not need to repeat the import every time the app starts. The downloaded JSON remains wherever you saved it; importing does not delete that original file.

Never commit your JSON, tokens, task cache, or authorization callback URLs. The app’s generic OAuth code is public; your configured account and credentials are not part of the repository.

## Upgrade an existing read-only sign-in

Existing `tasks.readonly` tokens continue to support viewing. Choose **Enable editing** in the panel or Settings to request the `tasks` scope through Google's consent flow. The app enables mutations only after Google returns the write grant; it does not assume that a saved read token permits editing.

Google's permission applies to all tasks in the authorized account, not a single selected list. Float Tasks separately restricts each mutation to a list currently visible in its local selection. That application check does not narrow the OAuth grant itself. See the official [Tasks scopes](https://developers.google.com/workspace/tasks/auth).

The upgrade keeps your selected list IDs but clears the old task view and snapshot before opening the browser, because the browser can select a different account. After a successful sign-in, it fetches tasks again. If the selected IDs do not exist in the chosen account, the app does not substitute other lists. The restored write grant normally survives future launches; Google can still expire or revoke it.

## Testing, Production, and sign-in lifetime

Keychain storage preserves the local sign-in across app launches. It cannot override Google’s expiration or revocation rules.

For an **External** project whose publishing status is **Testing**, Google issues refresh tokens that expire after seven days when requesting the Tasks scope. Expect to sign in again. Switching the audience to Production is a separate Google project configuration step; it is not a setting that Float Tasks can change. See Google’s [refresh-token expiration rules](https://developers.google.com/identity/protocols/oauth2#expiration).

Google currently requires homepage, privacy-policy, and terms URLs for external Production apps. Its branding guidance also requires appropriate authorized domains and domain ownership verification. Supply truthful pages for your own configured app and follow the console’s requirements; a public source repository alone does not guarantee approval. See [Manage OAuth App Branding](https://support.google.com/cloud/answer/15549049).

Google documents a [verification exception for personal-use apps with fewer than 100 users](https://support.google.com/cloud/answer/13464323). This does not guarantee exemption from all branding requirements or remove warning screens, account restrictions, or token-expiration rules. Production and verification are distinct states, and Production does not make tokens permanent. Organization administrators may impose additional restrictions.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Account cannot access a Testing app | Add that account as a test user in the project’s Audience settings. |
| Client JSON is rejected | Download JSON for a **Desktop app** client, then import it again. |
| Sign-in returns `invalid_grant` or stops working after a week | Sign in again; check Testing status, revocation, and Google’s token rules above. |
| Google Tasks API is disabled | Enable it in the same project that owns the imported client. |
| Sign-in callback times out | Keep the app running and check whether local security software blocks the temporary loopback connection. |
| Cached tasks remain while offline | Restore your network connection and refresh; the indicator reports the saved view. |
| Tasks are visible but editing is unavailable | Choose Enable editing and grant the `tasks` permission; an old read-only token cannot write. |
| A write may have succeeded despite a connection error | Refresh and inspect the task before retrying. The app does not automatically repeat writes. |
| Keychain access fails | Unlock your login keychain and follow the app’s error message. |

Use **Disconnect** to stop syncing and delete the app’s saved tokens and local task snapshot. Disconnect does not delete Google Tasks or revoke permission at Google; you can separately remove the authorization from your Google Account. See [Privacy](PRIVACY.md).
