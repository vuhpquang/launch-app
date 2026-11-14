#!/usr/bin/env bash
# build.sh
# Builds LaunchApp as a proper macOS .app bundle, signs it, packages into a DMG,
# and optionally notarizes.
#
# USAGE:
#   ./build.sh                  # Build + DMG, signed with "LaunchApp Self-Signed" if that
#                               # identity is in the keychain, otherwise ad-hoc
#   TEAM_ID="Developer ID Application: Name (ID)" ./build.sh   # Developer ID signed
#   NOTARIZE=1 TEAM_ID="..." ./build.sh                         # Signed + notarized
#
# Why a self-signed identity: an ad-hoc signature changes with every build, so macOS
# forgets the Accessibility grant (F4 key) after each update. A self-signed certificate gives a
# stable designated requirement ("certificate root = H…"), so the grant survives updates.
# It does not satisfy Gatekeeper — only a Developer ID + notarization does.

set -euo pipefail

BINARY_NAME="LaunchApp"
APP_NAME="LaunchApp"
APP_BUNDLE="${APP_NAME}.app"
BUILD_DIR="$(pwd)/build"
APP_PATH="${BUILD_DIR}/${APP_BUNDLE}"
DMG_PATH="${BUILD_DIR}/${BINARY_NAME}.dmg"
SELF_SIGNED_IDENTITY="LaunchApp Self-Signed"
if [[ -z "${TEAM_ID:-}" ]]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q "\"${SELF_SIGNED_IDENTITY}\""; then
        TEAM_ID="${SELF_SIGNED_IDENTITY}"
    else
        TEAM_ID="-"              # "-" = ad-hoc signing (works locally)
    fi
fi
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-LaunchApp}"
NOTARIZE="${NOTARIZE:-0}"

# ── STEP 0: Clean ──────────────────────────────────────────
echo "==> Preparing build directory…"
# Vendor/app-shell (shared updater / About / Settings shell) is a submodule pinned by commit.
git submodule update --init --recursive
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# ── STEP 1: Compile universal binary ───────────────────────
echo "==> Building universal release binary (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64
# Ask SwiftPM where it put the binary — the output folder differs between toolchains
# (.build/apple/… on older ones, .build/out/… on newer), and a hardcoded path silently
# packaged a stale binary.
BINARY_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${BINARY_NAME}"

if [[ ! -f "${BINARY_PATH}" ]]; then
    echo "ERROR: Binary not found at ${BINARY_PATH}" >&2
    exit 1
fi
echo "==> Build succeeded."

# ── STEP 2: Assemble .app bundle ───────────────────────────
# A proper macOS .app bundle has this layout:
#   LaunchApp.app/
#     Contents/
#       MacOS/
#         LaunchApp    ← the compiled binary
#       Info.plist           ← tells macOS about the app (name, bundle ID, LSUIElement, etc.)
#
# Without this structure macOS treats the binary as a Unix tool and opens it in Terminal.
echo "==> Assembling ${APP_BUNDLE}…"
mkdir -p "${APP_PATH}/Contents/MacOS"

# Copy the compiled binary into the bundle.
cp "${BINARY_PATH}" "${APP_PATH}/Contents/MacOS/${BINARY_NAME}"

# Copy Info.plist into the bundle root (Contents/).
cp "Sources/LaunchApp/Resources/Info.plist" "${APP_PATH}/Contents/Info.plist"

# Build AppIcon.icns from the 1024px master (regenerate it with scripts/make-icon.swift).
echo "==> Building AppIcon.icns…"
mkdir -p "${APP_PATH}/Contents/Resources"
ICONSET="${BUILD_DIR}/AppIcon.iconset"
ICON_SRC="Sources/LaunchApp/Resources/AppIcon.png"
mkdir -p "${ICONSET}"
for s in 16 32 128 256 512; do
    sips -z $s $s             "${ICON_SRC}" --out "${ICONSET}/icon_${s}x${s}.png"    >/dev/null
    sips -z $((s*2)) $((s*2)) "${ICON_SRC}" --out "${ICONSET}/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${APP_PATH}/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET}"

# ── STEP 3: Code-sign the .app bundle ──────────────────────
# Sign the whole bundle (not just the binary) so Gatekeeper is satisfied.
# With TEAM_ID="-" this is an ad-hoc signature — works on your own Mac only.
# With a real Developer ID certificate it passes Gatekeeper on any Mac.
echo "==> Code-signing ${APP_BUNDLE} with: ${TEAM_ID}"
codesign \
    --deep \
    --force \
    --sign "${TEAM_ID}" \
    "${APP_PATH}"

echo "==> Verifying signature…"
codesign --verify --deep --strict "${APP_PATH}"
echo "==> Signature OK."

# ── STEP 4: Create DMG ─────────────────────────────────────
# A styled DMG: background art (scripts/make-dmg-background.swift → packaging/), the app
# on the left and an Applications shortcut on the right. dmgbuild writes the Finder
# layout (.DS_Store) directly, so no Finder/AppleScript automation is needed. It runs
# from a private venv under .build/. If it can't be installed, fall back to a plain DMG.
echo "==> Creating DMG…"
DMGBUILD_VENV="$(pwd)/.build/dmgbuild-venv"
# A venv hardcodes its own path, so it breaks when the repo folder is moved or renamed:
# check that it actually runs, and rebuild it if not.
if ! "${DMGBUILD_VENV}/bin/python3" -c "import dmgbuild" >/dev/null 2>&1; then
    rm -rf "${DMGBUILD_VENV}"
    python3 -m venv "${DMGBUILD_VENV}" >/dev/null 2>&1 \
        && "${DMGBUILD_VENV}/bin/python3" -m pip install --quiet --disable-pip-version-check dmgbuild >/dev/null 2>&1 \
        || true
fi

if "${DMGBUILD_VENV}/bin/python3" -c "import dmgbuild" >/dev/null 2>&1; then
    "${DMGBUILD_VENV}/bin/python3" -m dmgbuild \
        -s scripts/dmg-settings.py \
        -D app="${APP_PATH}" \
        -D background="$(pwd)/packaging/dmg-background.png" \
        "${APP_NAME}" "${DMG_PATH}"
else
    echo "    (dmgbuild unavailable — building a plain DMG without background)"
    STAGING="${BUILD_DIR}/dmg_staging"
    mkdir -p "${STAGING}"
    cp -R "${APP_PATH}" "${STAGING}/"
    ln -s /Applications "${STAGING}/Applications"
    hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING}" \
        -fs HFS+ -format UDZO -ov "${DMG_PATH}"
    rm -rf "${STAGING}"
fi
echo "==> DMG created: ${DMG_PATH}"

# ── STEP 5 (optional): Notarize ────────────────────────────
if [[ "${NOTARIZE}" == "1" ]]; then
    echo "==> Submitting for notarization (this may take a few minutes)…"
    xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARYTOOL_PROFILE}" \
        --wait
    echo "==> Stapling notarization ticket…"
    xcrun stapler staple "${DMG_PATH}"
    echo "==> Notarization complete."
else
    echo "==> Notarization skipped (set NOTARIZE=1 to enable)."
fi

echo ""
echo "======================================================"
echo "  Done!  →  ${DMG_PATH}"
echo "======================================================"
