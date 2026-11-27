# File Explorer for macOS

A native macOS desktop file manager inspired by **Windows 11 (24H2) File Explorer**, built in **Swift 6** with **SwiftUI** and **AppKit**.

## Features

- **Windows 11 Fluent Chrome & Mica Surfaces**: Browser-style tab strip with drag-and-drop reordering and window tear-off, 44px address bar with interactive breadcrumbs, sibling folder menus, editable path mode (`Cmd+L`), and instant scoped search.
- **8 Layout Modes & Grouping**: Extra large / Large / Medium / Small icons, List, Details (resizable sortable columns), Tiles, and Content views, with collapsible Group By sections and optional item checkboxes.
- **Dedicated Destinations**: Home (Quick Access, Favorites, Recent), This Mac (folders & drives with capacity bars), Gallery (chronological photo timeline with year/month scrubber), Network discovery, and Trash (enumerate, restore, empty).
- **Rich Inspector & Dialogs**: Details pane, Preview pane (Images, PDFs, Text/Code/JSON/Markdown, Quick Look), Windows 11 24H2 Context Menu with Top Action Bar, Properties dialog (`General`, `Security` interactive `chmod` POSIX permissions, `Details`), Conflict Resolution dialog, and Folder Options & Appearance modal.
- **Real Filesystem Engine**: Live `DispatchSource` directory watching, async copy/move with progress & conflict resolution, `/usr/bin/ditto` ZIP compress & extract, Undo/Redo stack, bidirectional `NSPasteboard` cut/copy/paste, and JSON persistence under `~/Library/Application Support/FileExplorer/`.

## Requirements

- macOS 15.0+ (Apple Silicon / Intel)
- Swift 6.0+ / Xcode 16+

## Build, Test & Run

```bash
# Build all targets
swift build

# Run unit tests
swift test

# Run the app directly
swift run FileExplorerApp

# Run CLI smoke test
swift run FileExplorerApp --smoke-test

# Generate 10 Retina (1440x900 @2x) snapshot PNGs
swift run FileExplorerApp --snapshot-dir ./snapshots
```

### Build `.app` Bundle

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open build/FileExplorer.app
```

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+T` | New Tab |
| `Cmd+W` | Close Tab |
| `Cmd+N` | New Window |
| `Cmd+Shift+N` | New Folder |
| `Cmd+L` | Edit Path / Address Bar |
| `Cmd+F` | Focus Search |
| `Cmd+[` / `Cmd+]` | Back / Forward |
| `Cmd+Up` / `Backspace` | Up One Level |
| `Enter` | Open Selected Item |
| `F2` | Rename Selected Item |
| `Space` | Toggle Quick Look |
| `Cmd+I` | Properties Dialog |
| `Cmd+X` / `Cmd+C` / `Cmd+V` | Cut / Copy / Paste |
| `Cmd+D` | Duplicate |
| `Cmd+A` | Select All |
| `Cmd+Z` / `Cmd+Shift+Z` | Undo / Redo |
| `Cmd+Delete` | Move to Trash |
| `Cmd+Shift+.` | Toggle Hidden Files |
| `Cmd+R` | Refresh |
| `Cmd+,` | Folder Options & Appearance |

## Set as Default macOS File Viewer (`NSFileViewer`)

Use the included `sudo` helper scripts to install/enable File Explorer as your default folder viewer (`up.sh`) or cleanly restore macOS Finder (`down.sh`):

```bash
# Install to /Applications, set NSFileViewer, restart Finder, and launch File Explorer
sudo ./scripts/up.sh          # pass --rebuild to force rebuilding build/FileExplorer.app

# Quit File Explorer, restore Finder defaults, remove /Applications/FileExplorer.app, and relaunch Finder
sudo ./scripts/down.sh        # pass --keep-app to leave /Applications/FileExplorer.app installed
```

Or manage the `NSFileViewer` default manually after copying `build/FileExplorer.app` to `/Applications`:

```bash
defaults write -g NSFileViewer -string com.hackedple.fileexplorer && killall Finder
# Revert:
defaults delete -g NSFileViewer && killall Finder
```
