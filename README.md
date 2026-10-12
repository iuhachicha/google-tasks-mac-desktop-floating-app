# Float Tasks

A small native macOS menu-bar app that displays Google Tasks lists vertically in a translucent floating panel.

The panel starts at 280 points wide and can shrink to 240. Each list has its own collapsible card, so your tasks fit beside the work you are doing.

## Features

- Vertically stacked lists with active tasks, notes, and due dates.
- A transparent window with rounded material cards and adjustable opacity.
- Menu-bar click to show or hide; Escape, the close button, or an outside click to dismiss.
- Pinning to keep the panel open, a draggable header, and remembered window settings.
- Local search across list names, task titles, and notes.
- Direct Google Tasks API access, with a refresh check every 60 seconds while running.
- A local snapshot for offline viewing and macOS Keychain storage for sign-in credentials.

**This version is read-only.** Clicking a task opens Google Tasks in your browser. Creating, completing, and editing tasks happens there. The app fetches active tasks; it is not a full replacement for the Google Tasks interface.

## Build and run

The app targets macOS 13 or newer. Building requires Xcode Command Line Tools with Swift 6 and a macOS SDK; the toolchain itself may require a newer macOS version. Install the tools with `xcode-select --install` if they are missing.

```sh
git clone https://github.com/iuhachicha/google-tasks-mac-desktop-floating-app.git
cd google-tasks-mac-desktop-floating-app
./build.sh
open "dist/Float Tasks.app"
```

The script builds for the current Mac’s architecture; set `TARGET_ARCH=arm64` or `TARGET_ARCH=x86_64` to choose another supported target. It uses Apple’s frameworks without third-party package dependencies. The resulting app is an **ad-hoc signed developer build**, not an Apple-notarized release.

The app starts in the menu bar without a Dock icon or an automatically opened panel. Click the checklist icon to show it. You can move the built app to Applications in Finder.

## Connect your Google account

Each user supplies their own Google Cloud project and **Desktop app** OAuth client JSON. No shared OAuth client, account, or task data is included in this repository.

1. Follow [Google setup](docs/GOOGLE_SETUP.md) to enable the Tasks API and create your client.
2. Right-click the menu-bar icon and open **Settings…**.
3. Choose **Import Google client JSON…**, then **Sign in with Google**.
4. Complete Google’s consent flow in your default browser.

Import the file locally; never add it to Git, an issue, or a pull request. The app requests only `tasks.readonly` and saves the imported configuration and tokens in Keychain. It restores the saved sign-in when reopened, subject to Google’s token validity rules. External projects left in **Testing** normally require authorization again after seven days; the [setup guide](docs/GOOGLE_SETUP.md#testing-production-and-sign-in-lifetime) explains this limitation.

## Using the panel

| Action | How |
| --- | --- |
| Show or hide | Click the checklist menu-bar icon |
| Move | Drag the panel header |
| Resize | Drag an edge, or select a width in Settings |
| Collapse a list | Click its title; the choice is remembered |
| Search or refresh | Use the bottom toolbar |
| Keep open | Enable the pin button |
| Close Settings | Done, Escape, the window close button, or Command-W |
| Quit | Right-click the menu-bar icon and choose Quit |

The connection indicator distinguishes a live connection from an offline or saved view. The app must remain running to refresh; it does not install a background service.

## Development

```sh
./tests/run.sh
```

See [Architecture](docs/ARCHITECTURE.md) for the source layout and data flow, [Privacy](docs/PRIVACY.md) for storage and deletion details, and [Contributing](CONTRIBUTING.md) before opening a pull request.

## License

[MIT](LICENSE). Float Tasks is an independent project, not affiliated with or endorsed by Google.
