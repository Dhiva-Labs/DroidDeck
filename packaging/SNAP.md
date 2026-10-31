# Publishing DroidDeck to the Snap Store

Strict confinement, base `core24`, `plugin: flutter` plus the `gnome`
extension, built from source in LXD. Every plug is a standard one, so the
upload is not expected to need manual review and can be released to a channel
straight away. Do not upload a build whose confinement is not already
approved: a revision waiting in review blocks every later release of the snap
(see BranchPilot's packaging notes).

## Build

```bash
snapcraft pack --use-lxd        # -> adb-deck_<version>_<arch>.snap
```

The snap builds for `amd64` and `arm64` (`platforms:` in `snapcraft.yaml`).
Build on a machine of the architecture you want: snapcraft builds for the
host's architecture by default, and the Flutter engine is not cross-compiled.
The CI workflow does exactly that on a native runner for each architecture
and keeps both snaps as workflow artifacts (`snap-amd64`, `snap-arm64`); it
never uploads to the store.

* The Flutter SDK is cloned (stable channel) inside the build container, so
  the first build needs network and takes a few minutes. If it sits at
  "Linux SDK" on an idle dart download, kill that `dart` process inside the
  instance and the build carries on.
* Docker's `FORWARD DROP` policy can cut LXD's bridge so the container cannot
  reach the store or the archive. Allow the bridge first (sudo,
  non-persistent):
  `sudo iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT` and
  `sudo iptables -I DOCKER-USER -o lxdbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`.
* Build in LXD only. A bundle built on the host links against the host's
  glibc and will not start under core24.
* The lint warning about `libflutter_pty.so` being an unused library is
  expected: `flutter_pty` loads it with `dlopen`.

## Publish

```bash
snapcraft register adb-deck                         # once
snapcraft upload --release=stable adb-deck_1.0.3_amd64.snap
snapcraft upload --release=stable adb-deck_1.0.3_arm64.snap
```

Upload both files of a version: the store keeps one revision per architecture
under the same channel.

Bump `version` in `snap/snapcraft.yaml` together with `pubspec.yaml`.

## Connections users must make

None of these is auto-connected, so the store description tells users to run
them once after install:

```bash
sudo snap connect adb-deck:adb-support       # USB access to the phone (required for USB)
sudo snap connect adb-deck:raw-usb           # only if the phone is still not detected
sudo snap connect adb-deck:removable-media   # only to reach files on removable drives
```

Unplug and replug a phone that was already connected.

* `adb-support` and `raw-usb` are `deny-auto-connection` in snapd's base
  declaration, and `removable-media` is never auto-connected. Auto-connection
  of `adb-support` can be requested from the store team on the forum
  (https://forum.snapcraft.io/c/store-requests/19) if the manual step turns
  out to cost users; it is not needed to publish.
* `home`, `network`, `network-bind` and the desktop plugs connect
  automatically.

## Why each plug is there

| Plug | Why |
|---|---|
| `adb-support` | Opens `/dev/bus/usb` for Android vendor IDs and tags them into the device cgroup. While connected snapd also writes a udev rule giving those nodes mode 0666, so no host udev rule is needed. adb's default USB backend on Linux scans `/dev/bus/usb` directly, which is all this interface covers. |
| `raw-usb` | Fallback for a vendor ID missing from `adb-support`'s list (it dates from 2018). Adds every USB device node and sysfs reads. |
| `network` | `adb connect`, `adb pair`, and the app's socket to the adb server. |
| `network-bind` | The adb server listens on `127.0.0.1:5037`; `adb forward` and `reverse` bind ports too. |
| `home` | Pull, screenshots, recordings and APK extraction write to `~/Downloads`, `~/Pictures`, `~/Videos`; drag-and-drop and the file picker read from it. |
| `removable-media` | The same, on mounted external drives. |
| `desktop`, `wayland`, `x11`, `opengl`, ... | Added by the `gnome` extension. The file dialogs go through the desktop portal. |

## How adb is packaged

A confined app cannot run the host's `adb`, so `adb` is a `stage-packages`
entry (Ubuntu 24.04's 34.0.4, which the archive builds for both amd64 and
arm64). Three details matter:

* **Wrapper.** The app starts every adb with `LD_LIBRARY_PATH` removed, and
  Debian's adb finds its `android-lib*` libraries through an absolute
  RUNPATH that points outside the snap. `snap/local/adb-wrapper` replaces
  the `usr/bin/adb` symlink and restores the library path (the architecture's
  triplet comes from snapd's `SNAP_LAUNCHER_ARCH_TRIPLET`, so the same wrapper
  serves amd64 and arm64) before running
  `usr/lib/android-sdk/platform-tools/adb`.
* **Discovery.** The app runs `which adb`; the snap's `PATH` contains
  `$SNAP/usr/bin`, so it finds the wrapper without any app change.
* **Home directory.** The app runs with `HOME=$SNAP_REAL_HOME` so the folders
  above are the real ones. adb needs `~/.android` for its key, and a hidden
  directory in the real home is off limits, so the wrapper points adb's
  `HOME` at `$SNAP_USER_COMMON` (shared across revisions, so a refresh does
  not make the phone ask again).

`adb-deck.adb` is exposed as a second app: the same adb, for
`adb-deck.adb kill-server` and for use from a terminal.

Google's platform-tools zip was not used: the Android SDK licence does not
clearly allow redistributing it, whereas the archive build is Apache-2.0
source rebuilt by Ubuntu.

## What strict confinement costs

* **No scrcpy.** The app finds scrcpy through `PATH` and a few fixed
  locations, none of which a confined snap can reach on the host, and the
  archive's scrcpy 1.25 is too old for current Android releases. The Screen tab's mirroring
  card therefore shows "scrcpy not found", with advice (`sudo apt install
  scrcpy`) that does not apply to the snap. Bundling upstream's static
  release (scrcpy-linux-x86_64 tarball, checksummed) plus the `audio-playback`
  plug would add it; that was left out because it ships a prebuilt binary.
* **No mDNS discovery.** Ubuntu's adb is built without an mDNS backend
  (`adb mdns check` prints nothing, `adb mdns services` is always empty), so
  the Wireless tab's "Discovered on the network" list stays empty. Connect by
  IP and Android 11+ pairing work, because they are plain TCP.
* **Separate adb key.** The snap's adb has its own key, so a phone that
  trusts the host's adb asks to authorise this computer again.
* **The adb server outlives the window.** adb forks a background server that
  stays in the snap's cgroup scope, so snapd counts the snap as running and
  may postpone an automatic refresh until it is gone;
  `adb-deck.adb kill-server` stops it.
* **Existing host adb server.** If an adb server already runs on the host at
  port 5037, the app talks to that one over localhost; the snap's adb only
  starts its own when none is listening.
* **Recording and mirroring folders** are created in the real home, so a
  missing `~/Videos` is created rather than redirected.

## Test locally

```bash
sudo snap install --dangerous ./adb-deck_1.0.3_$(dpkg --print-architecture).snap
sudo snap connect adb-deck:adb-support
adb-deck.adb version                # Android Debug Bridge version 1.0.41 (34.0.4-debian)
adb-deck
```

Without a phone, a throwaway fake `adbd` (a few dozen lines of Python that
answers the CNXN handshake and `shell:` services on a loopback port,
attached with `adb-deck.adb connect 127.0.0.1:<port>`) is enough to exercise
the device page, logcat and the pty shell under confinement.
