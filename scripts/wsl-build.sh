#!/usr/bin/env bash
# Fork only. Builds the IPA on your own computer, inside WSL (Ubuntu), from the mod's files that the
# "Sync upstream and build" workflow publishes (artifact spoti-kit). The IPA never goes to GitHub.
#
#   scripts/wsl-build.sh [--dev] [decrypted.ipa]      (from the repo, inside WSL)
#
# The IPA defaults to the newest one in ipa/. Output: out/Spotify-<version>-mine.ipa, or -dev.ipa
# with --dev, which adds FLEX (vendor/): a debug build, where a three-finger long press shares the
# screen's view tree and the mod's log as a text file.
# First run installs the tools (asks for your Linux password once, for apt). The kit is fetched
# with Windows' gh.exe, so it uses the GitHub login you already have on Windows.
# Mirrors the injection half of scripts/pipeline.sh; keep them in step.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="dm2mymcszt-commits/spoti.pw"
TOOLS="$HOME/.spoti-tools"
LDID_URL="https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_linux_x86_64"
export PATH="$TOOLS/bin:$TOOLS/venv/bin:$PATH"

# ---- tools -------------------------------------------------------------------------------------
if ! command -v zip >/dev/null || ! command -v unzip >/dev/null || ! python3 -c 'import venv, ensurepip' 2>/dev/null; then
  echo "==> installing zip, unzip and python3-venv (sudo asks for your Linux password)"
  sudo apt-get update -qq
  sudo apt-get install -y -qq zip unzip python3-venv python3-pip curl git >/dev/null
fi
if ! command -v cyan >/dev/null; then
  echo "==> installing cyan"
  python3 -m venv "$TOOLS/venv"
  "$TOOLS/venv/bin/pip" install -q "cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw"
fi
if ! command -v ldid >/dev/null; then
  echo "==> installing ldid"
  mkdir -p "$TOOLS/bin"
  curl -fsSL "$LDID_URL" -o "$TOOLS/bin/ldid"
  chmod +x "$TOOLS/bin/ldid"
fi
command -v gh.exe >/dev/null || { echo "gh.exe not found: WSL can't see Windows' GitHub CLI (is Windows interop on?)" >&2; exit 1; }

# ---- inputs ------------------------------------------------------------------------------------
DEV=0
if [ "${1:-}" = "--dev" ]; then DEV=1; shift; fi
IN="${1:-$(ls -t "$ROOT"/ipa/*.ipa 2>/dev/null | head -1 || true)}"
[ -n "$IN" ] && [ -f "$IN" ] || { echo "no IPA: put your decrypted Spotify .ipa in ipa/, or pass its path" >&2; exit 1; }
IN="$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")"

echo "==> fetching the latest mod build (spoti-kit) from $REPO"
RUN_ID="$(gh.exe run list -R "$REPO" -w "Sync upstream and build" -b mine -s success -L 20 --json databaseId \
  --jq '.[].databaseId' | tr -d '\r' | while read -r id; do
    if gh.exe api "repos/$REPO/actions/runs/$id/artifacts" --jq '.artifacts[] | select(.name=="spoti-kit" and .expired==false) | .id' | grep -q .; then
      echo "$id"; break
    fi
  done)"
[ -n "$RUN_ID" ] || { echo "no unexpired spoti-kit artifact: run the Sync upstream and build workflow with force build on" >&2; exit 1; }
# gh.exe can only write to a Windows path, and permissions can't be set on /mnt/c, so the kit is
# downloaded to out/kit and then worked on from a copy in Linux's own file system.
DL="$ROOT/out/kit"
rm -rf "$DL" && mkdir -p "$DL"
gh.exe run download "$RUN_ID" -R "$REPO" -n spoti-kit -D "$(wslpath -w "$DL")"
WORK="$TOOLS/work"
KIT="$WORK/kit"
rm -rf "$WORK" && mkdir -p "$WORK"
cp -r "$DL" "$KIT"
echo "    run $RUN_ID, commit $(tr -d '\r\n' < "$KIT/COMMIT" | cut -c1-7)"

DEB="$(ls "$KIT"/*.deb | head -1)"
APPEX="$KIT/SpotifyGlassLiveActivity.appex"
GROUPS_DYLIB="$KIT/SpotifyGlassAppGroups.dylib"
INTENTS="$KIT/Metadata.appintents"
# Artifacts don't keep the executable bit.
find "$KIT" -type f -exec chmod 644 {} + && find "$KIT" -type d -exec chmod 755 {} +
chmod 755 "$APPEX/SpotifyGlassLiveActivity" "$GROUPS_DYLIB"

# ---- inject ------------------------------------------------------------------------------------
APP_DIR="$(unzip -Z1 "$IN" | grep -oE '^Payload/[^/]+\.app/' | sort -u | head -1)"
VERSION="$(unzip -p "$IN" "${APP_DIR}Info.plist" | python3 -c 'import plistlib,sys; print(plistlib.loads(sys.stdin.buffer.read())["CFBundleShortVersionString"])')"
SUFFIX=mine
FLEX=()
if [ "$DEV" = 1 ]; then
  SUFFIX=dev
  FLEX=("$ROOT/vendor/com.hopeless.autoflex_0.0.1_iphoneos-arm.deb")
fi
OUT="$WORK/Spotify-$VERSION-$SUFFIX.ipa"
FINAL="$ROOT/out/Spotify-$VERSION-$SUFFIX.ipa"
mkdir -p "$ROOT/out"

echo "==> injecting into Spotify $VERSION"
# -w drops the Watch app: its companion-app key would still name com.spotify.client and block the install.
cyan -i "$IN" -o "$OUT" -f "$DEB" ${FLEX[@]+"${FLEX[@]}"} "$APPEX" "$GROUPS_DYLIB" -l "$ROOT/plist/liquid-glass.plist" -w -s --overwrite

echo "==> loading the App Group shim in the home screen widget"
WIDGET_BIN="${APP_DIR}PlugIns/WidgetExtension.appex/WidgetExtension"
if unzip -l "$OUT" "$WIDGET_BIN" >/dev/null 2>&1; then
  PATCH="$(mktemp -d)"
  unzip -q "$OUT" "$WIDGET_BIN" -d "$PATCH"
  python3 "$ROOT/scripts/insert-dylib.py" "$PATCH/$WIDGET_BIN" @rpath/SpotifyGlassAppGroups.dylib
  # Fakesigned again with its own entitlements, the way cyan -s left it, for TrollStore.
  ldid -e "$PATCH/$WIDGET_BIN" > "$PATCH/ents.plist"
  ldid -S"$PATCH/ents.plist" "$PATCH/$WIDGET_BIN"
  (cd "$PATCH" && zip -q "$OUT" "$WIDGET_BIN")
  rm -rf "$PATCH"
else
  echo "    no WidgetExtension.appex in this IPA"
fi

echo "==> adding the Live Activity intents to Spotify's App Intents metadata"
python3 "$ROOT/scripts/merge-appintents.py" "$OUT" "$APP_DIR" "$INTENTS"

cp "$OUT" "$FINAL"
rm -rf "$WORK"
echo "==> done: $(wslpath -w "$FINAL")"
