#!/bin/bash
set -euo pipefail

# Linnix Release Script
# Creates a new release by tagging and pushing to GitHub

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 v0.1.1"
  exit 1
fi

# Validate version format
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Version must be in format vX.Y.Z (e.g., v0.1.1)"
  exit 1
fi

echo "🚀 Preparing release $VERSION..."

# Check for uncommitted changes
if [[ -n $(git status --porcelain) ]]; then
  echo "❌ Error: You have uncommitted changes. Commit or stash them first."
  git status --short
  exit 1
fi

# Verify we're on main branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "⚠️  Warning: You're on branch '$CURRENT_BRANCH', not 'main'"
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Check if tag already exists
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "❌ Error: Tag $VERSION already exists"
  exit 1
fi

# Run tests
echo "🧪 Running tests..."
make test

# Update version in Cargo.toml files
echo "📝 Updating Cargo.toml versions..."
VERSION_NUMBER="${VERSION#v}"  # Remove 'v' prefix

# Update workspace Cargo.toml
sed -i "s/^version = \".*\"/version = \"$VERSION_NUMBER\"/" Cargo.toml

# Update all crate Cargo.tomls
find . -name "Cargo.toml" -type f -not -path "*/target/*" -not -path "*/linnix-ai-ebpf/*" | while read -r toml; do
  if grep -q "^version = " "$toml"; then
    sed -i "s/^version = \".*\"/version = \"$VERSION_NUMBER\"/" "$toml"
  fi
done

# Commit version changes
git add .
if git diff --staged --quiet; then
  echo "ℹ️  No version changes to commit"
else
  git commit -m "chore: bump version to $VERSION"
  echo "✅ Committed version bump"
fi

# Create annotated tag
echo "🏷️  Creating tag $VERSION..."
git tag -a "$VERSION" -m "Release $VERSION

See https://github.com/linnix-os/linnix/releases/tag/$VERSION for details."

# Push to remote
echo "⬆️  Pushing to GitHub..."
git push origin main
git push origin "$VERSION"

echo ""
echo "✅ Release $VERSION created successfully!"
echo ""
echo "Next steps:"
echo "1. Go to https://github.com/linnix-os/linnix/releases/new?tag=$VERSION"
echo "2. Copy release notes and publish"
echo "3. Announce on social media"
