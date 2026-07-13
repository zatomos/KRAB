#!/usr/bin/env bash
#
# Publish a KRAB release.
# Build the signed APK, tag it, and publish it to GitHub Releases.
#
# Usage:
#   scripts/release.sh [--dry-run] [--repo owner/name] "Changelog line 1" ...
#
# The version comes from pubspec.yaml.
#
#   --dry-run          Build and check everything, publish nothing.
#   --repo owner/name  Publish to a repo other than this checkout's origin.

set -euo pipefail

export GH_PAGER=cat
export GIT_PAGER=cat
export GH_PROMPT_DISABLED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

# --- Parse args -----------------------------------------------------------
DRY_RUN=false
REPO_OVERRIDE=""
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true; shift ;;
    --repo)       REPO_OVERRIDE="${2:-}"; [[ -n "$REPO_OVERRIDE" ]] || die "--repo needs owner/name"; shift 2 ;;
    *) die "Unknown flag: $1" ;;
  esac
done
[[ $# -gt 0 ]] || die "Provide at least one changelog line.
Usage: scripts/release.sh [--dry-run] [--repo owner/name] \"line 1\" \"line 2\" ..."

# --- Dependencies ---------------------------------------------------------
for dep in flutter git gh; do
  command -v "$dep" >/dev/null || die "Missing dependency: $dep"
done
gh auth status >/dev/null 2>&1 \
  || die "gh is not authenticated. Run: gh auth login"

APKSIGNER="$(find "${ANDROID_HOME:-$HOME/Android/Sdk}" -name apksigner -type f 2>/dev/null | sort -V | tail -1)"
[[ -n "$APKSIGNER" ]] || die "apksigner not found. Set ANDROID_HOME, or install Android SDK build-tools."

# --- Repo, version, tag ---------------------------------------------------
ORIGIN_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
[[ -n "$ORIGIN_REPO" ]] || die "Could not determine the GitHub repo from this checkout."

REPO="${REPO_OVERRIDE:-$ORIGIN_REPO}"

# Publishing somewhere other than this checkout's origin.
OTHER_REPO=false
if [[ "$REPO" != "$ORIGIN_REPO" ]]; then
  OTHER_REPO=true
  echo
  echo "----------------------------------------------------------------"
  echo "Publishing to $REPO"
  echo "(Origin repo is still $ORIGIN_REPO)"
  echo "----------------------------------------------------------------"
fi

# Check for lib/config.dart
[[ -f lib/config.dart ]] || die \
"lib/config.dart is missing. Create it:
    cp lib/config.example.dart lib/config.dart
then set updateRepo to '$REPO'."

CONFIG_REPO="$(sed -nE "s/^const updateRepo = '([^']*)';.*/\1/p" lib/config.dart)"
[[ -n "$CONFIG_REPO" ]] || die \
"updateRepo is empty in lib/config.dart, so the app would never check for
updates. Set it to '$REPO'."
[[ "$CONFIG_REPO" == "$REPO" ]] || die \
"lib/config.dart points at '$CONFIG_REPO' but you are releasing to '$REPO'.
The app would look for its updates in the wrong repository. Fix lib/config.dart."

grep -qE '^const enableAutoUpdate = true;' lib/config.dart \
  || echo "    NOTE: enableAutoUpdate is false in lib/config.dart; this build will not self-update."

# Parse version
VERSION_LINE="$(grep -E '^version:' pubspec.yaml | sed -E 's/^version:[[:space:]]*//')"
VERSION="${VERSION_LINE%%+*}"
BUILD="${VERSION_LINE##*+}"
[[ -n "$VERSION" && -n "$BUILD" && "$VERSION" != "$BUILD" ]] \
  || die "pubspec.yaml version must look like '1.2.3+45', got: '$VERSION_LINE'"
TAG="v${VERSION}"
APK_NAME="krab-${VERSION}.apk"

log "Releasing $TAG (build $BUILD) to $REPO (dry-run=$DRY_RUN)"

# --- Preflight ------------------------------------------------------------
BLOCKERS=()
block() { if [[ "$DRY_RUN" == true ]]; then BLOCKERS+=("$1"); else die "$1"; fi; }

if [[ "$OTHER_REPO" == true ]]; then
  echo "    skipping the main/clean-tree/tag checks: they describe $ORIGIN_REPO's history"
else
  [[ -z "$(git status --porcelain)" ]] \
    || block "Working tree is dirty. Commit or stash first -- a release must correspond to a commit."

  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  [[ "$BRANCH" == "main" ]] \
    || block "On branch '$BRANCH'. Release from main."

  git fetch --tags --quiet
  git rev-parse "$TAG" >/dev/null 2>&1 \
    && block "Tag $TAG already exists. Bump 'version:' in pubspec.yaml."

  PREV_TAG="$(git tag --list 'v*' --sort=-v:refname | head -1)"
  if [[ -n "$PREV_TAG" ]]; then
    PREV_LINE="$(git show "$PREV_TAG:pubspec.yaml" 2>/dev/null | grep -E '^version:' | sed -E 's/^version:[[:space:]]*//' || true)"
    PREV_BUILD="${PREV_LINE##*+}"
    if [[ -n "$PREV_BUILD" && "$PREV_BUILD" != "$PREV_LINE" ]]; then
      if [[ "$BUILD" -gt "$PREV_BUILD" ]]; then
        echo "    build number $PREV_BUILD -> $BUILD (ok)"
      else
        block "Build number must increase: $PREV_TAG has +$PREV_BUILD, this release has +$BUILD.
   Bump the +N in pubspec.yaml's version."
      fi
    fi
  else
    echo "    no previous tag; this would be the first release"
  fi
fi

# Do not clobber a release already there
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
  && block "$REPO already has a release for $TAG. Bump 'version:' in pubspec.yaml."

# Check we can actually publish there befor* spending time building an APK.
REPO_JSON="$(gh api "repos/$REPO" 2>/dev/null || true)"
[[ -n "$REPO_JSON" ]] || die \
"Cannot read $REPO. Either it does not exist, or this token cannot see it.
    gh repo create ${REPO#*/} --public --add-readme
    gh auth status                 # is the token from GH_TOKEN? then unset it"

if [[ "$(jq -r '.permissions.push // false' <<<"$REPO_JSON" 2>/dev/null)" != "true" ]]; then
  die \
"This token has no write access to $REPO, so the release would be refused.
    gh auth status                 # a token 'from GH_TOKEN' ignores gh auth refresh
    env | grep -iE 'GH_TOKEN|GITHUB_TOKEN'
A fine-grained PAT must grant 'Contents: read and write' on $REPO specifically."
fi

# An empty repo has no commit for the tag to point at, and gh fails on it.
[[ "$(jq -r '.size // 0' <<<"$REPO_JSON" 2>/dev/null)" != "0" ]] \
  || echo "    NOTE: $REPO looks empty; if the release fails, give it a commit:
      gh repo create ${REPO#*/} --public --add-readme"

# --- Build ----------------------------------------------------------------
log "Building the release APK"
flutter build apk --release

APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$APK_PATH" ]] || die "APK not found at $APK_PATH"

# --- Verify the signature -------------------------------------------------
log "Verifying the APK signature"
"$APKSIGNER" verify "$APK_PATH" >/dev/null 2>&1 \
  || die "apksigner could not verify the APK."

CERT="$("$APKSIGNER" verify --print-certs "$APK_PATH" 2>/dev/null | grep -m1 'certificate DN:' || true)"
[[ -n "$CERT" ]] || die "Could not read the APK signature."
echo "    $CERT"
if grep -qi 'CN=Android Debug' <<<"$CERT"; then
  die "This APK is signed with the DEBUG key. Set up android/key.properties (see README) before releasing."
fi

# --- Release notes --------------------------------------------------------
NOTES="$(printf -- '- %s\n' "$@")"

echo
echo "--- Release notes ---"
echo "$NOTES"
echo "---------------------"

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run: nothing was tagged or published."
  echo "    APK: $APK_PATH"
  echo "    It is signed and installable -- side-load it to test."
  if [[ ${#BLOCKERS[@]} -gt 0 ]]; then
    echo
    echo "A real release would be REFUSED for ${#BLOCKERS[@]} reason(s):"
    for b in "${BLOCKERS[@]}"; do echo " - $b"; done
    exit 1
  fi
  echo
  echo "No blockers: 'scripts/release.sh \"...\"' would publish $TAG."
  exit 0
fi

# --- Publish --------------------------------------------------------------
log "Publishing $TAG to $REPO"
cp "$APK_PATH" "build/$APK_NAME"

# Tag the exact commit being released.
TARGET_ARGS=()
[[ "$OTHER_REPO" == true ]] || TARGET_ARGS=(--target "$(git rev-parse HEAD)")

gh release create "$TAG" \
  --repo "$REPO" \
  --title "KRAB $VERSION" \
  --notes "$NOTES" \
  "${TARGET_ARGS[@]}" \
  "build/$APK_NAME#$APK_NAME"

log "Done."
gh release view "$TAG" --repo "$REPO" --json url -q .url
