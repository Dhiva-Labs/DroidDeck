# Changelog

## 1.0.3

### Added

- Files tab: **Rename…** in a file or folder's menu. The dialog preselects the
  name without its extension. A name that is already taken is refused rather
  than overwritten. Changing only the case (`IMG.JPG` → `img.jpg`) works on
  the case-insensitive `/sdcard`.

### Changed

- Files tab: the New folder and Rename dialogs reject a name that contains `/`
  or is `.` or `..`, and keep the button disabled until the name is valid.

## 1.0.2

### Added

- Linux arm64 build: a `droiddeck_<version>_arm64.deb` next to the x86-64 one.
- `adb-deck` snap for Snap Store, strictly confined, for amd64 and arm64. adb
  is bundled in the snap.
- CI builds, tests and smoke-runs the app and the snap on native x64 and arm64
  runners, and attaches the `.deb` of each architecture to a published release.

### Changed

- `packaging/build_deb.sh` builds the package for the architecture of the
  machine it runs on (amd64 or arm64).
- The README install section names the arm64 package.

## 1.0.1

### Fixed

- Shell tab: the built-in terminal sets `TERM=xterm-256color`, so full-screen
  tools such as `top` and `vi` render correctly when DroidDeck is launched from
  the app grid.

### Changed

- Wireless tab: after enabling TCP debugging, a note explains that port 5555
  stays open on the device, with a one-click **Revert to USB** (`adb usb`)
  button.

## 1.0.0

First release: live device dashboard, logcat viewer, app manager, device file
explorer, screen tools, wireless debugging and an interactive adb shell.
