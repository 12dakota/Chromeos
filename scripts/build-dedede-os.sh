#!/usr/bin/env bash
# One script: public ChromiumOS tree + Firefox in rootfs + custom splash + USB image.
# Run on a workstation or a large Actions runner (self-hosted or GitHub larger runner).
# Not for locked production firmware.
set -euo pipefail

BOARD="${BOARD:-dedede}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-stable}"
CROS_ROOT="${CROS_ROOT:-$HOME/chromiumos}"
INCLUDE_FIREFOX="${INCLUDE_FIREFOX:-1}"
FIREFOX_VERSION="${FIREFOX_VERSION:-140.0}"
OUT_DIR="${OUT_DIR:-$PWD/flash}"

need() { command -v "$1" >/dev/null || { echo "missing $1"; exit 1; }; }

echo "== board=${BOARD} root=${CROS_ROOT} firefox=${INCLUDE_FIREFOX} =="
mkdir -p "$CROS_ROOT" "$OUT_DIR"

if [ -z "${PATH##*depot_tools*}" ] || [ -d "${HOME}/depot_tools" ]; then
  export PATH="${HOME}/depot_tools:${PATH}"
fi
if ! command -v repo >/dev/null; then
  git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "${HOME}/depot_tools"
  export PATH="${HOME}/depot_tools:${PATH}"
fi
need repo
need git

git config --global --add safe.directory '*' || true

cd "$CROS_ROOT"
if [ ! -d .repo ]; then
  repo init -u https://chromium.googlesource.com/chromiumos/manifest -b "$MANIFEST_BRANCH"
fi
repo sync -j"${REPO_JOBS:-8}"

OVERLAY="$CROS_ROOT/src/overlays/overlay-custom-firefox"
if [ "$INCLUDE_FIREFOX" = "1" ]; then
  echo "== writing overlay-custom-firefox (Firefox + splash) =="
  mkdir -p \
    "$OVERLAY/profiles" \
    "$OVERLAY/metadata" \
    "$OVERLAY/www-client/firefox-bin/files" \
    "$OVERLAY/chromeos-base/firefox-desktop-hook" \
    "$OVERLAY/chromeos-base/firefox-bootsplash/files/splash"

  echo custom-firefox > "$OVERLAY/profiles/repo_name"
  cat > "$OVERLAY/metadata/layout.conf" << 'EOF'
masters = portage-stable chromiumos
profile-formats = portage-2
repo-name = custom-firefox
EOF

  cat > "$OVERLAY/www-client/firefox-bin/files/firefox-wrapper.sh" << 'EOF'
#!/bin/sh
exec /opt/firefox/firefox "$@"
EOF
  chmod 0755 "$OVERLAY/www-client/firefox-bin/files/firefox-wrapper.sh"

  cat > "$OVERLAY/www-client/firefox-bin/files/firefox.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Firefox
Exec=/usr/local/bin/firefox %u
Icon=firefox
Terminal=false
Categories=Network;WebBrowser;
EOF

  cat > "$OVERLAY/www-client/firefox-bin/firefox-bin-${FIREFOX_VERSION}.ebuild" << EOF
EAPI="7"
DESCRIPTION="Official Mozilla Firefox in the ChromiumOS rootfs"
HOMEPAGE="https://www.mozilla.org/firefox/"
SRC_URI="https://ftp.mozilla.org/pub/firefox/releases/\${PV}/linux-x86_64/en-US/firefox-\${PV}.tar.xz"
LICENSE="MPL-2.0"
SLOT="0"
KEYWORDS="amd64"
RESTRICT="mirror strip"
S="\${WORKDIR}/firefox"
src_install() {
  dodir /opt/firefox
  cp -a "\${S}"/. "\${ED}/opt/firefox/" || die
  fperms 0755 /opt/firefox/firefox
  exeinto /usr/local/bin
  newexe "\${FILESDIR}/firefox-wrapper.sh" firefox
  insinto /usr/share/applications
  doins "\${FILESDIR}/firefox.desktop"
}
EOF

  cat > "$OVERLAY/chromeos-base/firefox-desktop-hook/firefox-desktop-hook-1.ebuild" << 'EOF'
EAPI="7"
DESCRIPTION="Firefox plus custom boot splash for a custom ChromiumOS image"
LICENSE="BSD"
SLOT="0"
KEYWORDS="*"
RDEPEND="www-client/firefox-bin chromeos-base/firefox-bootsplash"
DEPEND="${RDEPEND}"
EOF

  mkdir -p /tmp/ff-splash
  cat > /tmp/ff-splash/boot-logo.svg << 'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="800" viewBox="0 0 1280 800">
  <rect width="1280" height="800" fill="#0b1a2b"/>
  <circle cx="500" cy="360" r="110" fill="#ff7139"/>
  <circle cx="500" cy="360" r="58" fill="#0b1a2b"/>
  <circle cx="780" cy="360" r="110" fill="none" stroke="#4285f4" stroke-width="28"/>
  <circle cx="780" cy="360" r="42" fill="#4285f4"/>
  <text x="640" y="560" text-anchor="middle" font-size="36" fill="#f4f7fb">Firefox x ChromiumOS</text>
</svg>
SVG
  if command -v rsvg-convert >/dev/null && command -v convert >/dev/null; then
    rsvg-convert -w 1280 -h 800 /tmp/ff-splash/boot-logo.svg -o "$OVERLAY/chromeos-base/firefox-bootsplash/files/splash/boot_splash_frame01.png"
  else
    # fallback placeholder so the package still installs
    printf '\x89PNG\r\n' > "$OVERLAY/chromeos-base/firefox-bootsplash/files/splash/boot_splash_frame01.png"
  fi
  cp /tmp/ff-splash/boot-logo.svg "$OVERLAY/chromeos-base/firefox-bootsplash/files/splash/"

  cat > "$OVERLAY/chromeos-base/firefox-bootsplash/firefox-bootsplash-1.ebuild" << 'EOF'
EAPI="7"
DESCRIPTION="Custom Firefox x ChromiumOS boot splash"
LICENSE="BSD"
SLOT="0"
KEYWORDS="*"
S="${WORKDIR}"
src_install() {
  insinto /usr/share/chromeos-assets/images_100_percent
  doins "${FILESDIR}/splash/boot_splash_frame01.png" || die
  insinto /usr/share/firefox-os-splash
  doins "${FILESDIR}/splash/"* || die
}
EOF
fi

echo "== cros_sdk / setup_board / build_packages / build_image =="
cd "$CROS_ROOT"
chromite/bin/cros_sdk --create || true
chromite/bin/cros_sdk -- bash -lc "
  set -euo pipefail
  setup_board --board=${BOARD}
  if [ -d /mnt/host/source/src/overlays/overlay-custom-firefox ]; then
    emerge-${BOARD} chromeos-base/firefox-desktop-hook
  fi
  cros build-packages --board=${BOARD}
  cros build-image --board=${BOARD} --no-enable-rootfs-verification test
"

IMG_DIR="$CROS_ROOT/src/build/images/${BOARD}/latest"
SRC=""
for cand in chromiumos_test_image.bin chromiumos_image.bin chromiumos_base_image.bin; do
  if [ -f "$IMG_DIR/$cand" ]; then
    SRC="$IMG_DIR/$cand"
    break
  fi
done
test -n "$SRC"
echo "== packaging $SRC =="
if command -v zstd >/dev/null; then
  zstd -T0 -10 -f "$SRC" -o "$OUT_DIR/chromiumos_test_image-${BOARD}.bin.zst"
else
  gzip -c "$SRC" > "$OUT_DIR/chromiumos_test_image-${BOARD}.bin.gz"
fi
sha256sum "$OUT_DIR/"* | tee "$OUT_DIR/SHA256SUMS"
ls -lh "$OUT_DIR"
echo "== done. Write USB with: sudo dd if=<uncompressed .bin> of=/dev/sdX bs=4M status=progress conv=fsync =="
