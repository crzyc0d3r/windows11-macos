# Windows 11 for macOS

A **full native Windows 11 desktop shell replacement for macOS**, built in **Swift 6** (**SwiftUI** + **AppKit**) and integrated with **Karabiner-Elements**, **AltTab**, **Rectangle**, and a native **Windows 11 (24H2) File Explorer** (`FileExplorer.app`).

Designed to run with **System Integrity Protection (SIP) enabled** and switch cleanly between native macOS and the full Windows 11 environment using `./up` and `./down`.

---

## Quick Start (`./up` & `./down`)

```bash
# Enable the full Windows 11 desktop shell (snapshots your macOS settings first)
./up

# Restore original macOS (Dock, top Menu Bar, Finder, Karabiner, Rectangle, AltTab)
./down
```

### Supported Script Flags

| Command | Effect |
|---|---|
| `./up --dry-run` | Preview every `./up` action without modifying system defaults or apps |
| `./up --rebuild` | Force rebuilding `FileExplorer.app` and `Win11Shell.app` before installing |
| `./up --skip-brew` | Skip Homebrew cask installation (`karabiner-elements`, `alt-tab`, `rectangle`) |
| `./down --dry-run` | Preview every `./down` restore action without changing system state |
| `./down --keep-apps` | Restore macOS while keeping `/Applications/FileExplorer.app` and `/Applications/Win11Shell.app` |
| `./down --uninstall-brew` | Also uninstall Homebrew casks that were newly installed by `./up` |

*(Compatibility wrappers `scripts/up.sh` and `scripts/down.sh` delegate directly to `./up` and `./down`.)*

### What `./up` Snapshots & `./down` Restores

On first run, `./up` saves a one-time backup snapshot to `~/Library/Application Support/HackedpleWin11/backup/` covering:
- `com.apple.dock.plist` & `com.apple.finder.plist` (`CreateDesktop`, `QuitMenuItem`)
- Global defaults (`_HIHideMenuBar`, `NSFileViewer`)
- Existing Karabiner-Elements config (`~/.config/karabiner/karabiner.json`)
- Existing Rectangle (`com.knollsoft.Rectangle`) and AltTab (`com.lwouis.alt-tab-macos`) preferences
- Newly installed Homebrew casks (`installed-casks.txt`) and the `Win11Shell` LaunchAgent (`~/Library/LaunchAgents/com.hackedple.win11shell.plist`)

### One-Time macOS Permissions Checklist

After running `./up` the first time, grant these permissions in **System Settings → Privacy & Security** so global hotkeys, window bars, and live thumbnails work everywhere:
1. **Accessibility**: Enable `Win11Shell`, `AltTab`, and `Rectangle`
2. **Input Monitoring**: Enable `Win11Shell` and `karabiner_grabber`
3. **Screen Recording**: Enable `Win11Shell` and `AltTab` (used for live taskbar & `Alt+Tab` window thumbnails)
4. **Driver Extensions**: Allow the **Karabiner-Elements** DriverKit extension if prompted

---

## Shell Architecture & Features

### 1. Windows 11 Taskbar & System Tray (`Win11Shell.app`)
A full-width **48pt Acrylic/Mica taskbar** rendered per display (replaces Apple's hidden Dock, supports fullscreen auto-hide and optional taskbar auto-hide):
- **Center or Left Alignment**: Start button, Search (`Win+S`), Task View (`Win+Tab`), and pinned/running app icons (`FileExplorer` pinned first; Finder hidden).
- **Taskbar Interactions**: Active accent pill, left-click active app to minimize/hide, middle-click to open a new window, **live hover window previews** with per-window close (`✕`), and right-click Jump Lists (New Window, open windows, Pin/Unpin, Quit).
- **Widgets & System Stats Chip**: Live CPU load and memory usage badge opening a System & Widgets flyout.
- **`^` System Tray Overflow**: Mirrors third-party top-right macOS menu bar extras (`AXExtrasMenuBar`) into a bottom tray popover alongside Activity Monitor (Task Manager) and System Settings shortcuts.
- **Quick Settings Flyout (`Win+A`)**: Interactive Wi-Fi toggle/SSID, Bluetooth, Dark/Light mode, Hide Top Menu Bar, Auto-Hide Taskbar, Per-Window Menu Bar toggle, Display Brightness slider, Volume slider + mute, and Battery status.
- **Clock & Calendar Flyout (`Win+N`)**: Live clock, date, and interactive month calendar grid.
- **Show Desktop Sliver (`Win+D`)** & **Taskbar Settings** right-click menu.

### 2. Windows 11 Start Menu (`Win` / Start Button)
- Live prefix-ranked app search (`Enter` launches top match)
- 6-column **Pinned** apps grid with Pin/Unpin context actions and **All Apps** alphabetical list
- **Recommended** recent files from `~/Desktop`, `~/Downloads`, and `~/Documents`
- User profile badge and **Power** menu (`Lock`, `Sleep`, `Restart`, `Shut down`, `Sign out`)

### 3. Per-Window Self-Contained Menu Bar & Right-Side Controls (`— □ ✕`)
Because SIP prevents injecting views into other apps' native macOS titlebars, `Win11Shell` docks a **28pt bar flush above the focused window** (reserving `28pt` at the top and `48pt` at the bottom when maximizing):
- **Live Mirrored App Menus**: Reads the active app's `AXMenuBar` (`File`, `Edit`, `View`, etc., collapsing overflow into `•••`) so every window has its own self-contained Windows-style menu bar while macOS's top menu bar stays hidden.
- **Window Dragging & Double-Click Maximize**: Drag the strip to move any window; double-click to maximize/restore.
- **Right-Side Caption Buttons (`— □ ✕`)**:
  - `—` Minimize window
  - `□` / `❐` Maximize/Restore + **Windows 11 Snap Layouts** hover picker (`50/50`, `66/34`, quadrants)
  - `✕` Close window / **quit app on last window** (keeping background tray apps like Outlook, Teams, WhatsApp, OneDrive, and Tailscale alive)

### 4. macOS Dock, Top Menu Bar & Finder Suppression
- Hides Apple's native Dock (`autohide=true`, `autohide-delay=1000`, `autohide-time-modifier=0`, `no-bouncing=true`).
- Auto-hides the macOS top Menu Bar (`_HIHideMenuBar=true`) and consolidates system controls and tray icons into the bottom Taskbar.
- Sets `FileExplorer.app` (`com.hackedple.fileexplorer`) as the default folder handler (`NSFileViewer`), disables Finder desktop (`CreateDesktop=false`), enables `QuitMenuItem`, and intercepts Finder activations at runtime to redirect straight to `FileExplorer.app`.

### 5. Windows 11 (24H2) File Explorer (`FileExplorer.app`)
- **Fluent Chrome & Mica Surfaces**: Browser-style tab strip with drag-and-drop reordering and window tear-off, 44px address bar with interactive breadcrumbs, editable path bar, and instant scoped search.
- **8 Layout Modes & Grouping**: Extra large / Large / Medium / Small icons, List, Details (resizable sortable columns), Tiles, and Content views, with collapsible Group By sections and optional item checkboxes.
- **Destinations & Inspector**: Home, This Mac (drives with capacity bars), Gallery, Network, Trash, Details pane, Preview pane (Images, PDFs, Text/Code/JSON/Markdown, Quick Look), Properties (`General`, `Security` `chmod`, `Details`), and Conflict Resolution dialogs.
- **Real Filesystem Engine**: Live `DispatchSource` watching, async copy/move, `/usr/bin/ditto` ZIP compress & extract, Undo/Redo stack, and bidirectional `NSPasteboard` cut/copy/paste.

---

## Keyboard & Window Management

### Modifier Layout
On the built-in MacBook keyboard, Karabiner swaps `Option ↔ Command` at the device layer so **both the built-in keyboard and external PC keyboards share identical physical positions**:

```text
[ Ctrl ] [ Win ] [ Alt ] [ Space ]
```

- **Non-terminal apps**: `Ctrl+<key>` shortcuts map to macOS `Cmd+<key>` (`Ctrl+C`, `Ctrl+V`, `Ctrl+X`, `Ctrl+Z`, `Ctrl+Y` → Redo, `Ctrl+F`, `Ctrl+T`, `Ctrl+W`, etc.), while `Ctrl+Tab` stays native for switching tabs.
- **Terminal apps** (`Terminal`, `iTerm2`, `Ghostty`, `Warp`, `Alacritty`, `kitty`, `WezTerm`, `Hyper`): Raw `Ctrl` is preserved (`Ctrl+C` sends `SIGINT`); use `Win+C` / `Win+V` for copy/paste.

### Global Windows 11 Shortcuts

| Shortcut | Action |
|---|---|
| `Win` (tap) | Toggle Windows 11 Start Menu |
| `Win+S` | Open Start Menu focused on Search |
| `Win+E` | Open / focus `FileExplorer.app` |
| `Win+D` | Toggle Show Desktop |
| `Win+A` | Toggle Quick Settings flyout |
| `Win+N` | Toggle Clock & Calendar flyout |
| `Win+I` | Open System Settings |
| `Win+L` | Lock Screen (`Ctrl+Cmd+Q`) |
| `Win+Tab` | Open Task View (Mission Control) |
| `Win+Shift+S` | Interactive Snipping Tool (clipboard screenshot) |
| `Win+.` | Emoji & Symbols picker |
| `Ctrl+Shift+Esc` | Task Manager (Activity Monitor) |
| `Alt+Tab` | Live-thumbnail window switcher (`AltTab`) |
| `Alt+F4` | Close window / quit app on last window |
| `Win+Left` / `Win+Right` / `Win+Up` | Snap window Left Half / Right Half / Maximize (`Rectangle`) |
| `Win+Down` | Unmaximize window, or minimize if not maximized |
| `Win+Ctrl+Left` / `Win+Ctrl+Right` | Switch Virtual Desktops (macOS Spaces) |
| `Home` / `End` (and `+Shift`) | Line start / end |
| `Ctrl+Home` / `Ctrl+End` (and `+Shift`) | Document start / end |
| `Ctrl+Left` / `Ctrl+Right` (and `+Shift`) | Word jump / select |
| `Alt+Left` / `Alt+Right` | Back / Forward |
| `F5` / `Ctrl+F5` | Refresh / Hard Refresh |

### File Explorer Shortcuts (`FileExplorer.app`)

| Shortcut | Action |
|---|---|
| `Ctrl+T` / `Ctrl+W` / `Ctrl+N` | New Tab / Close Tab / New Window |
| `Ctrl+Shift+N` | New Folder |
| `Ctrl+L` / `Alt+D` | Edit Path / Address Bar |
| `Ctrl+F` | Focus Search |
| `Alt+Left` / `Alt+Right` | Back / Forward |
| `Alt+Up` / `Backspace` | Up One Level |
| `Enter` / `F2` / `Space` | Open / Rename / Quick Look |
| `Alt+Enter` / `Ctrl+I` | Properties Dialog |
| `Ctrl+X` / `Ctrl+C` / `Ctrl+V` | Cut / Copy / Paste |
| `Delete` | Move to Trash |
| `Ctrl+H` | Toggle Hidden Files |
| `F5` / `Ctrl+R` | Refresh |

---

## Repository Layout

```text
.
├── up                              # Full Windows 11 environment initializer
├── down                            # Full restore to original macOS
├── Package.swift                   # FileExplorer Swift 6 package
├── Sources/FileExplorer*           # Windows 11 File Explorer app modules
├── Tests/FileExplorerCoreTests/    # FileExplorer unit tests
├── Win11Shell/
│   ├── Package.swift               # Win11Shell Swift 6 package
│   ├── Sources/Win11ShellCore/     # Config, Karabiner/Rectangle/AltTab generators, geometry, close policy, app catalog
│   ├── Sources/Win11ShellApp/      # Taskbar, Start Menu, Quick Settings, Calendar, Per-Window Bar, AX/Hotkey/Finder bridges
│   └── Tests/Win11ShellCoreTests/  # Win11ShellCore unit tests
└── scripts/
    ├── build-app.sh                # Builds signed build/FileExplorer.app
    ├── build-win11shell.sh         # Builds signed build/Win11Shell.app
    ├── up.sh                       # Delegates to ../up
    └── down.sh                     # Delegates to ../down
```

---

## Requirements & Build / Test

- **macOS 15.0+** (Apple Silicon / Intel)
- **Swift 6.0+** / **Xcode 16+**
- **Homebrew** (optional; used by `./up` to install `karabiner-elements`, `alt-tab`, and `rectangle`)

```bash
# Test Win11ShellCore & build Win11Shell.app
cd Win11Shell && swift test && cd ..
./scripts/build-win11shell.sh
./build/Win11Shell.app/Contents/MacOS/Win11ShellApp --smoke-test

# Test FileExplorerCore & build FileExplorer.app
swift test
./scripts/build-app.sh
```
