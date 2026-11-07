# Rclone GUI

A lightweight native macOS app (SwiftUI, no dependencies) for browsing and managing cloud storage through [rclone](https://rclone.org). It runs your installed `rclone` binary and uses your existing `rclone.conf`, so every remote you already have shows up automatically.

## Features

- **Sidebar of remotes** with a type icon and a storage usage bar (from `rclone about`, for backends that support it).
- **Finder-style browser** with breadcrumbs, back/forward, a sortable Name/Size/Modified table, and a filter field.
- **File operations:** new folder, rename, delete (with a confirmation), and copy path, from the toolbar or the right-click menu.
- **Upload** with the toolbar button or by **dragging files and folders from Finder** onto the list.
- **Download** to any folder.
- **Quick Look** works like in Finder. Select a file and press Space (or ⌘Y, the eye button in the toolbar, or "Quick Look" in the right-click menu). The preview follows your selection while it's open, and "Open with Preview" is one click away. Files are fetched through the file cache, so previewing them again is instant.
- **File cache.** Double-clicking a file opens it from a local cache in `~/Library/Caches/RcloneGUI/files`. If the file hasn't changed on the remote (same size and modification time), it opens instantly without downloading again. If the remote can't be reached, the last cached copy is opened instead. The size limit defaults to 2 GB and can be changed in **Settings**, which also shows how much is used and has a Clear Cache button. When the cache is over the limit, the least recently opened files are removed first. Folders you've already visited show their last listing instantly while a fresh one loads in the background.
- **Transfers panel** with live progress, speed and ETA (parsed from rclone's JSON stats), cancel buttons, and Show in Finder.
- **Folder sync:** the toolbar's Sync menu mirrors a local folder to the current remote folder, or the other way, with `rclone sync`. It asks first, because files that exist only at the destination get deleted.
- **Menu bar icon:** a cloud that turns into a sync cloud while jobs are running. Click it to see each job's progress, cancel jobs, or reopen the main window. The app keeps running in the menu bar after you close the window, so transfers continue.
- **App icon with light and dark versions:** light is a white tile with an iCloud-style blue gradient cloud; dark is a black tile with a desaturated cloud. `scripts/make-icon.swift` writes an Icon Composer document (`Resources/AppIcon.icon`) and `bundle.sh` compiles it with `actool`. macOS shows the dark version when *System Settings → Appearance → Icon & widget style* is set to Dark.
- **Fast on slow-to-connect remotes:** the app keeps one `rclone rcd` running in the background, listening only on 127.0.0.1 with a random password and stopped when the app quits. Folder listings and file fetches reuse its remote connections instead of starting rclone and logging in again each time. Opening a cached file that the folder listing shows is unchanged skips rclone entirely. If the background rclone can't start, the app falls back to running a separate rclone for each action.
- **Loading feedback:** while a file is being fetched for Quick Look or opening, its row shows a spinner and a floating bar shows progress with a Cancel button.
- **Add Remote wizard** built from `rclone config providers` (all ~70 backends). It shows the required and optional fields, then asks rclone's follow-up questions inside the app, including browser OAuth sign-in for Google Drive, Dropbox, OneDrive and others.
- **Remove remote.** This only deletes the config entry and never touches the cloud files.

## Requirements

- macOS 14 or later
- rclone. If it isn't found, the app shows a setup screen with three choices:
  - **Download & Install** fetches the latest official build from rclone.org and checks it against rclone's published SHA-256 checksum. It installs to `~/Library/Application Support/RcloneGUI/bin/rclone` and needs no admin password.
  - **Install with Homebrew** runs `brew install rclone` and shows its output live. This option only appears when Homebrew is installed.
  - **Choose rclone…** lets you point the app at an rclone you already have.

  The app looks for rclone in this order: the custom path from **Settings (⌘,)**, then Homebrew, `/usr/local/bin`, `~/bin`, and finally the copy it installed itself.

## Build & run

```bash
./scripts/bundle.sh          # builds build/Rclone.app (release, ad-hoc signed)
open build/Rclone.app
```

To develop, use `swift build && swift run`, or open `Package.swift` in Xcode.

To try it without touching your real config, launch it with a different config file:

```bash
open -n --env RCLONE_CONFIG=/path/to/test.conf build/Rclone.app
```

## Shortcuts

| Key | Action |
| --- | --- |
| ⌘R | Refresh |
| ⌘[ / ⌘] | Back / Forward |
| ⌘↑ | Enclosing folder |
| Return / double-click | Open folder or file |
| ⌫ | Delete selection (asks first) |

## Layout

```
Sources/RcloneGUI/
  Rclone.swift        rclone process runner, JSON models (entries, about, providers)
  Transfer.swift      long-running copy jobs with live progress + cancel
  AppModel.swift      app state: remotes, navigation, file ops, transfers
  RcloneGUIApp.swift  app entry, menus, Settings
  ContentView.swift / SidebarView.swift / BrowserView.swift
  TransfersView.swift / AddRemoteView.swift
  MenuBarView.swift   menu bar icon (drawn progress bar) + jobs popover
scripts/bundle.sh     packages the release build into a .app
scripts/make-icon.swift  renders the app icon
```
