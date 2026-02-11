#!/usr/bin/env bash
# Update Homebrew formula SHA256 hashes from a GitHub release.
# Usage: ./update-formula.sh <version>
# Example: ./update-formula.sh 0.1.0
set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
FORMULA="$(dirname "$0")/Formula/cljw.rb"
BASE_URL="https://github.com/chaploud/ClojureWasm/releases/download/v${VERSION}"

TARGETS=(
  "cljw-macos-aarch64:PLACEHOLDER_SHA256_MACOS_AARCH64"
  "cljw-macos-x86_64:PLACEHOLDER_SHA256_MACOS_X86_64"
  "cljw-linux-aarch64:PLACEHOLDER_SHA256_LINUX_AARCH64"
  "cljw-linux-x86_64:PLACEHOLDER_SHA256_LINUX_X86_64"
)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "Downloading release artifacts for v${VERSION}..."
for entry in "${TARGETS[@]}"; do
  name="${entry%%:*}"
  placeholder="${entry##*:}"
  file="${name}.tar.gz"

  curl -sL "${BASE_URL}/${file}" -o "${tmpdir}/${file}"
  sha=$(sha256sum "${tmpdir}/${file}" | cut -d' ' -f1)
  echo "  ${name}: ${sha}"

  sed -i.bak "s/${placeholder}/${sha}/g" "$FORMULA"
done

# Update version
sed -i.bak "s/version \"[^\"]*\"/version \"${VERSION}\"/" "$FORMULA"
rm -f "${FORMULA}.bak"

echo "Updated ${FORMULA} for v${VERSION}"
