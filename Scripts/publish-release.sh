#!/bin/bash
set -euo pipefail

: "${GH_REPO:?GitHub repository is required}"
: "${GITHUB_REF_NAME:?Version tag is required}"
: "${GITHUB_SHA:?Tagged commit is required}"

RELEASE_TAG="$GITHUB_REF_NAME"
ASSET_DIRECTORY="build/release"
RELEASE_STATE="build/release-state.json"
ASSETS=(
    "$ASSET_DIRECTORY/ClassicLaunchpad-$RELEASE_TAG-arm64.zip"
    "$ASSET_DIRECTORY/ClassicLaunchpad-$RELEASE_TAG-x86_64.zip"
    "$ASSET_DIRECTORY/SHA256SUMS.txt"
)
for asset in "${ASSETS[@]}"; do
    test -s "$asset"
done

ALREADY_PUBLISHED=false
if gh release view "$RELEASE_TAG" --repo "$GH_REPO" --json isDraft --jq '.isDraft' > "$RELEASE_STATE" 2> build/release-lookup.log; then
    case "$(cat "$RELEASE_STATE")" in
        false) ALREADY_PUBLISHED=true ;;
        true) ;;
        *) printf 'Cannot determine existing Release state.\n' >&2; exit 1 ;;
    esac
else
    NOTE_ARGUMENTS=(--generate-notes)
    NOTE_FILE=".github/release-notes/$RELEASE_TAG.md"
    if [[ -f "$NOTE_FILE" ]]; then
        NOTE_ARGUMENTS=(--notes-file "$NOTE_FILE")
    fi
    gh release create "$RELEASE_TAG" --repo "$GH_REPO" --verify-tag \
        --target "$GITHUB_SHA" --title "启动台 ${RELEASE_TAG#v}" --draft "${NOTE_ARGUMENTS[@]}"
fi

if [[ "$ALREADY_PUBLISHED" == false ]]; then
    # Only drafts may be resumed or have their assets replaced on a retry.
    gh release upload "$RELEASE_TAG" --repo "$GH_REPO" --clobber "${ASSETS[@]}"
fi

# The REST tag lookup only returns published releases. Resolve drafts by ID.
RELEASE_ID="$(gh release view "$RELEASE_TAG" --repo "$GH_REPO" --json databaseId --jq '.databaseId')"
if [[ ! "$RELEASE_ID" =~ ^[0-9]+$ ]]; then
    printf 'Cannot determine Release ID.\n' >&2
    exit 1
fi
gh api "repos/$GH_REPO/releases/$RELEASE_ID" > "$RELEASE_STATE"
python3 - "$RELEASE_STATE" "$ALREADY_PUBLISHED" "${ASSETS[@]}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

state = json.loads(Path(sys.argv[1]).read_text())
already_published = sys.argv[2] == "true"
remote = {asset["name"]: asset for asset in state["assets"]}
for filename in sys.argv[3:]:
    local = Path(filename)
    asset = remote.get(local.name)
    if asset is None or asset["state"] != "uploaded" or asset["size"] <= 0:
        raise SystemExit(f"Missing or incomplete Release asset: {local.name}")
    if not already_published:
        if asset["size"] != local.stat().st_size:
            raise SystemExit(f"Release asset size does not match: {local.name}")
        digest = asset.get("digest")
        expected = "sha256:" + hashlib.sha256(local.read_bytes()).hexdigest()
        if digest and digest != expected:
            raise SystemExit(f"Release asset checksum does not match: {local.name}")
print("Verified both architecture archives and the checksum file.")
PY

if [[ "$ALREADY_PUBLISHED" == true ]]; then
    printf 'Release %s is already published; existing assets were preserved.\n' "$RELEASE_TAG"
else
    # Expose the Release only after the complete upload has been verified.
    gh release edit "$RELEASE_TAG" --repo "$GH_REPO" --draft=false --latest
fi
