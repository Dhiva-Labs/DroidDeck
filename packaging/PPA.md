# Publishing DroidDeck to the Dhiva Labs PPA

DroidDeck is published to `ppa:dhiva-labs/apps` as the `droiddeck` package,
for Ubuntu 24.04 (noble) on amd64. Launchpad builds it from a source package
that carries the Flutter SDK and pub cache (see `packaging/vendor/README`),
because its builders have no network.

Signing needs the Dhiva Labs GPG key (`3D8D857AAF4D50E6`) and its
passphrase, so the last two steps are run by the key holder. The `dhiva-apps`
target in `~/.dput.cf` points at `~dhiva-labs/ubuntu/apps/`.

## 1. Bump debian/changelog

Add an entry on top for the new version. Keep the `~noble<N>` suffix and the
`noble` series, and raise `<N>` to re-upload the same app version:

```
droiddeck (1.0.4~noble1) noble; urgency=medium

  * <what changed>

 -- Dhiva Labs <dhivakar1010@gmail.com>  <date -R>
```

## 2. Build the source package from a clean export

Build from `git archive`, never from the working tree: the tree holds
`build/`, `dist/`, `PLAN.md` and other local files, and `dh_auto_clean`
deletes `build/`. The vendored tarballs are git-ignored, so copy them in.

```bash
V=1.0.4~noble1
W=$(mktemp -d)
git archive --prefix=droiddeck-$V/ HEAD | tar -x -C "$W"
cp packaging/vendor/*.tar.xz "$W/droiddeck-$V/packaging/vendor/"
(cd "$W/droiddeck-$V" && dpkg-buildpackage -S -sa -us -uc -d)
ls "$W"   # droiddeck_<V>.dsc, .tar.xz, _source.changes, _source.buildinfo
```

Rebuild `pub-cache-3.44.6.tar.xz` first if `pubspec.lock` changed since the
last upload.

## 3. Rehearse the Launchpad build offline (optional, recommended)

A failed Launchpad build costs a version bump and 15–30 minutes. Build the
source package in a network namespace to catch anything that reaches for the
network:

```bash
cd "$W" && dpkg-source -x droiddeck_$V.dsc rehearsal && cd rehearsal
unshare -rn dpkg-buildpackage -b -us -uc -d
```

On a machine whose clang picks a GCC without libstdc++ headers, add
`DEB_CFLAGS_APPEND=--gcc-install-dir=<dir>` (and the CXXFLAGS and LDFLAGS
equivalents). Launchpad's noble builders don't need it.

## 4. Sign and upload (key holder)

```bash
cd "$W"
debsign -k3D8D857AAF4D50E6 droiddeck_${V}_source.changes
dput dhiva-apps droiddeck_${V}_source.changes
```

`dput` saying "Successfully uploaded packages" only means the FTP transfer
finished. Launchpad accepts or rejects the upload later, by email. Two cases
report success but upload nothing:

- **A repeat upload.** After a transfer, dput writes
  `droiddeck_<V>_source.dhiva-apps.upload` and silently skips any later
  upload of the same version. After a rejection, delete that file and use
  `dput -f`.
- **An unregistered signing key.** Launchpad discards uploads signed by a key
  it doesn't know.

## 5. Watch the build

<https://launchpad.net/~dhiva-labs/+archive/ubuntu/apps/+packages>

Once published, users install with:

```bash
sudo add-apt-repository ppa:dhiva-labs/apps
sudo apt update
sudo apt install droiddeck
```
