#!/bin/zsh
# Builds, zips and publishes a GitHub release, then updates the Homebrew cask in bythebug/homebrew-tap.
#   scripts/release.sh 0.3.0
# Not notarized yet (no Developer ID, PLAN.md Q3); the cask tells users how to allow the first launch.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?usage: scripts/release.sh <version>}
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first." >&2; exit 1; }

swift test
VERSION=$version scripts/build-app.sh
lipo -info build/CopyCopied.app/Contents/MacOS/copycopied
zip=build/CopyCopied.zip
rm -f "$zip"
ditto -c -k --keepParent build/CopyCopied.app "$zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)

git tag "v$version"
git push -q origin main "v$version"
gh release create "v$version" "$zip" --repo bythebug/copycopied --title "CopyCopied $version" \
  --notes "Install: \`brew install --cask bythebug/tap/copycopied\` (not notarized yet; see the caveat after install)."

tap=$(brew --repository bythebug/tap)
git -C "$tap" pull -q
cat > "$tap/Casks/copycopied.rb" <<CASK
cask "copycopied" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/bythebug/copycopied/releases/download/v#{version}/CopyCopied.zip"
  name "CopyCopied"
  desc "Menu bar app that tells you when a camera card is safely copied and verified"
  homepage "https://github.com/bythebug/copycopied"

  depends_on macos: :sonoma

  app "CopyCopied.app"

  caveats <<~EOS
    CopyCopied is not notarized yet. Allow the first launch with:
      xattr -dr com.apple.quarantine /Applications/CopyCopied.app
  EOS
end
CASK
grep -q "bythebug/tap/copycopied" "$tap/README.md" ||
  sed -i '' 's#^brew install --cask bythebug/tap/fastwifi$#&\nbrew install --cask bythebug/tap/copycopied#' "$tap/README.md"
git -C "$tap" add Casks/copycopied.rb README.md
git -C "$tap" commit -qm "copycopied $version"
git -C "$tap" push -q
echo "Released $version: brew install --cask bythebug/tap/copycopied"
