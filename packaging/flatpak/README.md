# Flatpak

`com.dhivalabs.droid_deck.yml` builds the DroidDeck Flatpak bundle that CI
attaches to releases (`droiddeck-<version>-x86_64.flatpak` and
`-aarch64.flatpak`).

## How CI builds and tests it

The `flatpak` job in `.github/workflows/ci.yml` unpacks the installed tree of
the `.deb` built earlier in the same run into `packaging/flatpak/tree/` and
runs flatpak-builder on the manifest in the
`ghcr.io/flathub-infra/flatpak-github-actions:gnome-51` image, natively on an
x64 and an arm64 runner. The bundle therefore ships the same Flutter build as
the `.deb`, `.rpm`, Arch package and AppImage.

The manifest has two modules:

- **host-tools**: `/app/bin/adb` and `/app/bin/scrcpy`, links to one script
  that runs the host's command of the same name with `flatpak-spawn --host`,
  passing on `TERM` (the interactive shell needs it), `ANDROID_ADB_SERVER_PORT`
  and `ANDROID_SERIAL`.
- **droiddeck**: the installed tree, with the desktop file and icons renamed
  to the app ID, and the AppStream metadata.

The `flatpak-run` job then installs the bundle the way a user would, with
the GNOME 51 runtime from Flathub, on a plain Ubuntu runner that has the
distribution's `adb`. Inside the sandbox it checks that every ELF file under
`/app` finds its libraries (`ldd-check.sh`) and that `which adb` and
`which scrcpy` (how the app looks for them) give the shims. Last,
`packaging/linux-distros/smoke.sh` starts the app under Xvfb and waits for a
painted Flutter UI, the app's own `[DroidDeck] adb: /app/bin/adb v...` line
and `[DroidDeck] tracker: connected (host:track-devices-l)`: the app ran
`adb start-server` through the shim, the server started on the host, and the
app's socket to it on 127.0.0.1:5037 works from inside the sandbox.

## Why adb runs on the host

Google's platform-tools have no Linux arm64 build, and building adb from
source (the android-tools project) needs Go and protobuf, which the GNOME SDK
does not have. More to the point, users already have an adb server running on
their system, with their udev rules and authorised keys (`~/.android`). The
sandbox shares the host's network, so a second adb of another version inside
it would meet the host's server on port 5037, and the two kill each other's
server on a version mismatch. So the Flatpak uses the host's adb, the way
IDE Flatpaks reach host tools.

## Permissions

| Permission | Why |
|---|---|
| `--socket=wayland`, `--socket=fallback-x11`, `--share=ipc`, `--device=dri` | display and GPU for the Flutter UI |
| `--share=network` | the adb server on 127.0.0.1:5037 and wireless debugging |
| `--talk-name=org.freedesktop.Flatpak` | the adb and scrcpy shims (`flatpak-spawn --host`) |
| `--filesystem=home` | pushed and pulled files, dropped APKs, screenshots and recordings (`~/Pictures/droiddeck`), extracted APKs and logcat exports (`~/Downloads`); the host's adb reads and writes these, so the paths must be the same inside and outside |
| `--device=all` | USB devices, for an adb chosen in Settings (for example `~/Android/Sdk/platform-tools/adb`), which runs inside the sandbox |

`--talk-name=org.freedesktop.Flatpak` lets the app run any command on the
host. That is a sandbox escape, used here for exactly adb and scrcpy.

## Limits

- adb (and scrcpy, for mirroring) must be installed on the system. Without
  it the app reports that adb is not found, as the `.deb` does.
- Files to push or install must be under the home directory, where the
  host's adb sees the same path.
- No phone is attached on CI, so device operations are covered by the
  unit tests and the `.deb`, not by this Flatpak job.

## Flathub

A Flathub submission would differ in two ways:

1. The `droiddeck` module's `tree` directory source becomes an `archive`
   source pointing at the release `.deb` with its sha256, or the app is built
   from source with the Flutter SDK and every pub package listed as sources,
   since Flathub builds offline.
2. Flathub reviews `--talk-name=org.freedesktop.Flatpak` and `--device=all`
   closely; the reasons are the table above.

Each release also needs a `<release>` line in
`com.dhivalabs.droid_deck.metainfo.xml`.
