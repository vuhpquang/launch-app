#!/usr/bin/env bash
# scripts/release.sh — cut a LaunchApp release end to end.
#
#   scripts/release.sh 1.0.1                    # notes generated from commits
#   scripts/release.sh 1.0.1 notes.md           # notes from a Markdown file
#   DRY_RUN=1 scripts/release.sh 1.0.1          # build + verify only, then undo the bump
#   INSTALL=1 scripts/release.sh 1.0.1          # also replace /Applications/LaunchApp.app
#   PUBLISH=0 INSTALL=1 scripts/release.sh 1.0.1  # offline (office network): commit + tag
#                                               # locally and install, no push / GitHub release
#
# A PUBLISH=0 release is pushed later: push main with --follow-tags, then create its GitHub
# release from the tag (the ship-check skill does both).
#
# Steps: preflight → bump Info.plist → swift test → ./build.sh → verify the signer →
# commit + tag + push main → GitHub release with LaunchApp.dmg.
#
# Installed copies only accept updates signed by the same certificate, so the script
# refuses to publish anything not signed by RELEASE_CERT ("LaunchApp Self-Signed").

set -euo pipefail
cd "$(dirname "$0")/.."

REPO="vuhpquang/launch-app"
BRANCH="main"
PLIST="Sources/LaunchApp/Resources/Info.plist"
DMG="build/LaunchApp.dmg"
APP="build/LaunchApp.app"
SIGN_IDENTITY="LaunchApp Self-Signed"
RELEASE_CERT="904e41a3be84695f944abc74242ed06eec7a6c09"   # SHA-1 of that certificate
DRY_RUN="${DRY_RUN:-0}"
PUBLISH="${PUBLISH:-1}"

die()  { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

VERSION="${1:-}"
NOTES_FILE="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh X.Y.Z [notes.md]"
[[ -z "$NOTES_FILE" || -f "$NOTES_FILE" ]] || die "notes file not found: $NOTES_FILE"
TAG="v${VERSION}"

step "Preflight"
[[ "$(git branch --show-current)" == "$BRANCH" ]] || die "release from '$BRANCH'"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean"
if [[ "$PUBLISH" == "1" && "$DRY_RUN" != "1" ]]; then
    git fetch -q origin "$BRANCH" --tags
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BRANCH")" ]] || die "$BRANCH is not in sync with origin"
    gh auth status >/dev/null 2>&1 || die "gh is not logged in"
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
security find-identity -p codesigning | grep -q "\"$SIGN_IDENTITY\"" \
    || die "signing identity '$SIGN_IDENTITY' not in keychain (import ~/.config/launchapp-signing/launchapp-signing.p12)"

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
newest="$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
[[ "$VERSION" != "$CURRENT" && "$newest" == "$VERSION" ]] || die "$VERSION must be newer than $CURRENT"
echo "    $CURRENT (build $BUILD) → $VERSION (build $((BUILD + 1)))"

COMMITTED=0
undo() {
    if [[ "$DRY_RUN" == "1" || "$COMMITTED" == "0" ]]; then git checkout -q -- "$PLIST"; fi
}
trap undo EXIT

step "Bumping $PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"

step "Running tests"
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
swift test >/dev/null 2>&1 || die "tests failed (run 'swift test')"

step "Building"
TEAM_ID="$SIGN_IDENTITY" ./build.sh

step "Verifying the release"
codesign --verify --deep --strict "$APP"
built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$built" == "$VERSION" ]] || die "bundle says $built, expected $VERSION"
codesign -d -r- "$APP" 2>&1 | grep -qiE "certificate (root|leaf) = H\"$RELEASE_CERT\"" \
    || die "LaunchApp.app is not signed by the release certificate — installed copies would reject it"
[[ "$(lipo -archs "$APP/Contents/MacOS/LaunchApp")" == *arm64* ]] || die "missing arm64 slice"
[[ "$(lipo -archs "$APP/Contents/MacOS/LaunchApp")" == *x86_64* ]] || die "missing x86_64 slice"
echo "    signed by release certificate, universal, $DMG sha256 $(shasum -a 256 "$DMG" | awk '{print $1}')"

if [[ "$DRY_RUN" == "1" ]]; then
    step "Dry run — stopping before commit; version bump reverted. Artifacts are in build/."
    exit 0
fi

step "Committing and tagging $TAG"
git add "$PLIST"
git commit -q -m "release: $TAG"
COMMITTED=1
git tag -a "$TAG" -m "LaunchApp $VERSION"
if [[ "$PUBLISH" == "1" ]]; then
    git push -q --follow-tags origin "$BRANCH" "$TAG"

    step "Creating GitHub release $TAG"
    if [[ -n "$NOTES_FILE" ]]; then
        gh release create "$TAG" "$DMG" -R "$REPO" --title "LaunchApp $VERSION" --notes-file "$NOTES_FILE" --latest
    else
        gh release create "$TAG" "$DMG" -R "$REPO" --title "LaunchApp $VERSION" --generate-notes --latest
    fi
fi

if [[ "${INSTALL:-0}" == "1" ]]; then
    step "Installing to /Applications"
    osascript -e 'quit app id "com.vuhpquang.launchapp"' >/dev/null 2>&1 || true
    sleep 1
    rm -rf /Applications/LaunchApp.app
    ditto "$APP" /Applications/LaunchApp.app
    xattr -dr com.apple.quarantine /Applications/LaunchApp.app 2>/dev/null || true
fi

step "Released LaunchApp $VERSION"
if [[ "$PUBLISH" == "1" ]]; then
    echo "    https://github.com/$REPO/releases/tag/$TAG"
else
    echo "    local only: commit + tag $TAG not pushed, no GitHub release yet"
fi
