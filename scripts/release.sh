#!/usr/bin/env bash
#
# Build the release APK, upload it to Nextcloud, create a public download link,
# and append the release to the manifest the app reads.
#
# Usage:
#   scripts/release.sh [--mandatory|-m] "Changelog line 1" "Changelog line 2" ...
#
# The version is read from pubspec.yaml. Config lives in scripts/release.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Load config ----------------------------------------------------------
ENV_FILE="$SCRIPT_DIR/release.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Copy scripts/release.env.example and fill it in." >&2
  exit 1
fi
source "$ENV_FILE"

: "${NC_BASE_URL:?set in release.env}"
: "${NC_USER:?set in release.env}"
: "${NC_PASS:?set in release.env}"
: "${NC_DIR:?set in release.env}"
: "${NC_MANIFEST_PATH:?set in release.env}"
MAX_RELEASES="${MAX_RELEASES:-}"

for dep in flutter curl jq; do
  command -v "$dep" >/dev/null || { echo "Missing dependency: $dep" >&2; exit 1; }
done

# --- Parse args -----------------------------------------------------------
MANDATORY=false
if [[ "${1:-}" == "--mandatory" || "${1:-}" == "-m" ]]; then
  MANDATORY=true
  shift
fi
if [[ $# -eq 0 ]]; then
  echo "Provide at least one changelog line." >&2
  echo "Usage: scripts/release.sh [--mandatory|-m] \"line 1\" \"line 2\" ..." >&2
  exit 1
fi
CHANGELOG_JSON="$(printf '%s\n' "$@" | jq -R . | jq -s .)"

# --- Version --------------------------------------------------------------
# pubspec "version: 1.2.3+45" -> strip the +build suffix.
VERSION="$(grep -E '^version:' "$ROOT_DIR/pubspec.yaml" | sed -E 's/^version:[[:space:]]*//; s/\+.*//')"
[[ -n "$VERSION" ]] || { echo "Could not read version from pubspec.yaml" >&2; exit 1; }
APK_NAME="krab-${VERSION}.apk"

echo "==> Releasing v${VERSION} (mandatory=${MANDATORY})"

# --- Build ----------------------------------------------------------------
echo "==> Building release APK..."
( cd "$ROOT_DIR" && flutter build apk --release )
APK_PATH="$ROOT_DIR/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$APK_PATH" ]] || { echo "APK not found at $APK_PATH" >&2; exit 1; }

# --- Nextcloud helpers ----------------------------------------------------
DAV="$NC_BASE_URL/remote.php/dav/files/$NC_USER"
OCS="$NC_BASE_URL/ocs/v2.php/apps/files_sharing/api/v1/shares"
AUTH=(-u "$NC_USER:$NC_PASS")

# Ensure the remote dir exists
curl -fsS "${AUTH[@]}" -X MKCOL "$DAV/$NC_DIR" >/dev/null 2>&1 || true

# --- Upload APK -----------------------------------------------------------
echo "==> Uploading $APK_NAME ..."
curl -fsS "${AUTH[@]}" -T "$APK_PATH" "$DAV/$NC_DIR/$APK_NAME" >/dev/null

# --- Create public share for the APK --------------------------------------
echo "==> Creating public link..."
SHARE_JSON="$(curl -fsS "${AUTH[@]}" -H "OCS-APIRequest: true" \
  -d "path=/$NC_DIR/$APK_NAME" -d "shareType=3" -d "permissions=1" \
  "$OCS?format=json")"
TOKEN="$(echo "$SHARE_JSON" | jq -r '.ocs.data.token // empty')"
[[ -n "$TOKEN" ]] || { echo "Failed to create share: $SHARE_JSON" >&2; exit 1; }
DOWNLOAD_URL="$NC_BASE_URL/index.php/s/$TOKEN/download"
echo "    $DOWNLOAD_URL"

# --- Fetch + update manifest ----------------------------------------------
echo "==> Updating manifest..."
CURRENT="$(curl -fsS "${AUTH[@]}" "$DAV/$NC_MANIFEST_PATH" 2>/dev/null || echo '{"releases":[]}')"
echo "$CURRENT" | jq empty 2>/dev/null || CURRENT='{"releases":[]}'

UPDATED="$(echo "$CURRENT" | jq \
  --arg v "$VERSION" \
  --arg url "$DOWNLOAD_URL" \
  --argjson mand "$MANDATORY" \
  --argjson cl "$CHANGELOG_JSON" \
  '.releases = ((.releases // []) | map(select(.version != $v)))
                + [{version: $v, downloadUrl: $url, changelog: $cl, mandatory: $mand}]')"

# Optional prune: keep mandatory releases and the most recent MAX_RELEASES
if [[ -n "$MAX_RELEASES" ]]; then
  UPDATED="$(echo "$UPDATED" | jq --argjson max "$MAX_RELEASES" '
    (.releases // []) as $r
    | ($r | map(select(.mandatory))) as $m
    | ($r[-$max:]) as $recent
    | .releases = ($r | map(select((($m | index(.)) != null) or (($recent | index(.)) != null))))')"
fi

echo "$UPDATED" | jq . | curl -fsS "${AUTH[@]}" -T - "$DAV/$NC_MANIFEST_PATH" >/dev/null

echo "==> Done. Manifest now advertises:"
echo "$UPDATED" | jq -r '.releases[] | "    \(.version)\(if .mandatory then " (mandatory)" else "" end)"'
