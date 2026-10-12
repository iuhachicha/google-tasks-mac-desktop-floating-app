# Native panel design

Float Tasks keeps a small, readable task list beside the user's work. Its defining feature is a narrow column of softly frosted cards. It uses SwiftUI and AppKit controls, SF Symbols, and system fonts; no web view or third-party UI framework is involved.

## Hierarchy and layout

- Keep the same vertical layout from 240 to 460 points. The default width is 280 points.
- Let the list title lead, followed by Add Task and the active tasks. Keep completed items behind disclosure.
- Show remaining counts with the list instead of repeating them throughout the panel.
- Keep common icon targets at least 28 points and give controls visible interaction feedback.
- Use a 12-point outer margin and aligned inner spacing. Let task titles and errors wrap.
- Keep Settings actions outside its scrolling body so Done remains reachable when connection errors are long.

Compact and regular widths use the same structure:

```text
240 points                460 points
╭ Tasks · drag ╮           ╭ Tasks · drag                    ╮
╭ List · count╮           ╭ List · count                    ╮
│ + Add Task  │           │ + Add Task                      │
│ ○ Task title│           │ ○ Task title                    │
│   wraps here│           │   Notes and date                │
│ ▸ Completed │           │ ▸ Completed                     │
╰─────────────╯           ╰─────────────────────────────────╯
╭ tools · sync╮           ╭ tools · sync ╮
```

## Type, color, and motion

Use system text styles for task content and metadata, with a 15-point semibold list title. Primary and secondary semantic colors adapt to light and dark appearances. Accent color identifies actions and selected controls; completion retains its checkmark as well as its color.

Standard material provides the floating surface. With Reduce Transparency or Increase Contrast, cards use an opaque system surface and the window becomes fully opaque. The saved opacity setting is restored when those accessibility preferences are disabled. Disclosure motion is brief and disabled by Reduce Motion; do not animate routine task writes.

Material contrast depends on the desktop underneath and the system appearance. A static color-pair ratio does not establish contrast for the whole panel. Check light, dark, and accessibility appearances on the running app, including the minimum width.

## Implementation constraints

The outer list container must remain an eager `VStack`, and AppKit must own the panel size (`NSHostingView.sizingOptions = []`). A lazy outer container previously caused a layout loop at the bottom of long lists. Run `./tests/run-scroll.sh` after structural changes.

Keep editors and delete confirmation inline. A failed request must preserve its draft. Visual changes must not change the selected-list filter, authentication, or API behavior.

## Design references

The [Apple Design skill](https://github.com/dickwu/apple-design-skill) informed this pass, translated to the app's native macOS context. Key references are Apple's guidance on [typography](https://developer.apple.com/design/human-interface-guidelines/typography), [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [layout](https://developer.apple.com/design/human-interface-guidelines/layout), [materials](https://developer.apple.com/design/human-interface-guidelines/materials), and [settings](https://developer.apple.com/design/human-interface-guidelines/settings).
