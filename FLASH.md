# Flash a custom dedede ChromiumOS image

This is for a Chromebook **you own** that is already in **developer mode**.
It is not a Google-signed recovery image. A locked production device will not boot it.

## What GitHub-hosted Actions cannot do

A full `setup_board` + `build_packages` + `build_image` for `dedede` needs on the order of:

- 16+ CPU cores
- 32+ GB RAM
- 300+ GB free disk
- several hours

`ubuntu-latest` will run out of disk. The repo currently has **no self-hosted runners**.

## Self-hosted runner

1. On a large Linux workstation, install a GitHub Actions runner for `12dakota/Chromeos`.
2. Give it labels: `self-hosted`, `linux`, `x64`, `cros-builder`.
3. Run workflow **Build dedede ChromiumOS USB flash image**.
4. Download `chromiumos_test_image-dedede.bin.zst` from Releases.

## Local build (same commands the workflow runs)

```bash
mkdir -p ~/chromiumos && cd ~/chromiumos
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ~/depot_tools
export PATH="$HOME/depot_tools:$PATH"

repo init -u https://chromium.googlesource.com/chromiumos/manifest -b stable
repo sync -j8

# optional Firefox overlay from the last successful overlay release
curl -L -o overlay-custom-firefox.tar.gz \
  https://github.com/12dakota/Chromeos/releases/download/dedede-cros-repo-2/overlay-custom-firefox.tar.gz
tar -xzf overlay-custom-firefox.tar.gz -C src/overlays

cros_sdk
setup_board --board=dedede
emerge-dedede chromeos-base/firefox-desktop-hook
cros build-packages --board=dedede
cros build-image --board=dedede --no-enable-rootfs-verification test
```

Image path:

```text
~/chromiumos/src/build/images/dedede/latest/chromiumos_test_image.bin
```

## Write USB

```bash
zstd -d chromiumos_test_image-dedede.bin.zst
# confirm the disk name first: lsblk
sudo dd if=chromiumos_test_image-dedede.bin of=/dev/sdX bs=4M status=progress conv=fsync
```

Boot the USB on the developer-mode Chromebook and install with the official
`chromeos-install` / `cros flash` flow from the ChromiumOS developer guide.
