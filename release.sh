#!/usr/bin/env bash
# release.sh — Semver release automation for agent-sandbox
# Usage: ./release.sh [major|minor|patch|current]
set -euo pipefail

# --- Helpers ---

err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '[release] %s\n' "$*"; }

# --- Read current version ---

VERSION_FILE="$(dirname "$0")/VERSION"
[[ -f "$VERSION_FILE" ]] || err "VERSION file not found"

CURRENT_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")

# Validate semver format (X.Y.Z)
if [[ ! "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "VERSION file contains invalid semver: '$CURRENT_VERSION' (expected X.Y.Z)"
fi

# --- Parse command ---

ACTION="${1:-current}"

case "$ACTION" in
    current)
        echo "$CURRENT_VERSION"
        exit 0
        ;;
    major|minor|patch)
        ;;
    *)
        echo "Usage: $0 [major|minor|patch|current]" >&2
        echo "" >&2
        echo "  major    Bump major version (X.0.0)" >&2
        echo "  minor    Bump minor version (x.Y.0)" >&2
        echo "  patch    Bump patch version (x.y.Z)" >&2
        echo "  current  Print current version (default)" >&2
        exit 1
        ;;
esac

# --- Ensure clean working tree ---

if ! git diff --quiet HEAD 2>/dev/null; then
    err "Working tree is dirty. Commit or stash changes before releasing."
fi

if ! git diff --cached --quiet 2>/dev/null; then
    err "Staged changes exist. Commit or stash before releasing."
fi

# --- Bump version ---

IFS='.' read -r major minor patch_num <<< "$CURRENT_VERSION"

case "$ACTION" in
    major) major=$((major + 1)); minor=0; patch_num=0 ;;
    minor) minor=$((minor + 1)); patch_num=0 ;;
    patch) patch_num=$((patch_num + 1)) ;;
esac

NEW_VERSION="${major}.${minor}.${patch_num}"
TAG="v${NEW_VERSION}"

# Check tag doesn't already exist
if git tag -l "$TAG" | grep -q "$TAG"; then
    err "Tag $TAG already exists"
fi

log "Bumping: ${CURRENT_VERSION} → ${NEW_VERSION}"

# --- Update VERSION file ---

echo "$NEW_VERSION" > "$VERSION_FILE"

# --- Update CHANGELOG.md ---

CHANGELOG="$(dirname "$0")/CHANGELOG.md"
DATE=$(date '+%Y-%m-%d')

if [[ -f "$CHANGELOG" ]]; then
    # Check for [Unreleased] section
    if grep -q '^\## \[Unreleased\]' "$CHANGELOG"; then
        # Replace [Unreleased] with versioned section
        sed -i.bak "s/^## \[Unreleased\]/## [${NEW_VERSION}] - ${DATE}/" "$CHANGELOG"
        rm -f "${CHANGELOG}.bak"
        log "Updated CHANGELOG.md: [Unreleased] → [${NEW_VERSION}] - ${DATE}"
    else
        # Insert new version section after the first heading
        sed -i.bak "/^# Changelog/a\\
\\
## [${NEW_VERSION}] - ${DATE}" "$CHANGELOG"
        rm -f "${CHANGELOG}.bak"
        log "Inserted [${NEW_VERSION}] section in CHANGELOG.md"
    fi
else
    log "WARN: CHANGELOG.md not found — skipping changelog update"
fi

# --- Commit and tag ---

git add "$VERSION_FILE"
[[ -f "$CHANGELOG" ]] && git add "$CHANGELOG"

git commit -m "release: v${NEW_VERSION}

Bump version ${CURRENT_VERSION} → ${NEW_VERSION}"

git tag -a "$TAG" -m "Release ${TAG}

Version ${NEW_VERSION} released on ${DATE}"

log "Created commit and tag: ${TAG}"
log ""
log "Next steps:"
log "  git push origin main --tags    # Push to remote"
log "  # GitHub Actions will create a Release automatically"
