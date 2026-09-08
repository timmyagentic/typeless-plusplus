#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
configuration="${CONFIGURATION:-release}"
artifact_root="${ARTIFACT_ROOT:-$repo_root/dist}"
app_path="$artifact_root/Typeless++.app"
code_sign_identity="${CODE_SIGN_IDENTITY:--}"

swift build \
  --package-path "$repo_root" \
  --configuration "$configuration" \
  --product TypelessPlusPlus

binary_dir="$(swift build \
  --package-path "$repo_root" \
  --configuration "$configuration" \
  --show-bin-path)"

if [[ ! -x "$binary_dir/TypelessPlusPlus" ]]; then
  echo "Built executable is missing: $binary_dir/TypelessPlusPlus" >&2
  exit 1
fi

if [[ -e "$app_path" ]]; then
  rm -rf "$app_path"
fi

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/TypelessPlusPlus" "$app_path/Contents/MacOS/TypelessPlusPlus"
cp "$repo_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$repo_root/Resources/PkgInfo" "$app_path/Contents/PkgInfo"
cp "$repo_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
chmod 755 "$app_path/Contents/MacOS/TypelessPlusPlus"

# SwiftPM links binary frameworks but does not embed their runtime helpers.
sparkle_source="$repo_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$sparkle_source" ]]; then
  echo "Resolved Sparkle framework is missing" >&2
  exit 1
fi
mkdir -p "$app_path/Contents/Frameworks"
ditto "$sparkle_source" "$app_path/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app_path/Contents/MacOS/TypelessPlusPlus"

plutil -lint "$app_path/Contents/Info.plist" >/dev/null
codesign_arguments=(
  --force
  --sign "$code_sign_identity"
  --options runtime
)
if [[ "$code_sign_identity" == "-" ]]; then
  codesign_arguments+=(--timestamp=none)
else
  codesign_arguments+=(--timestamp)
fi
# Sign from the inside out with the same identity. Do not use --deep to sign.
sparkle="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
for helper in "$sparkle"/XPCServices/*.xpc "$sparkle/Autoupdate" "$sparkle/Updater.app"; do
  if [[ -e "$helper" ]]; then
    codesign "${codesign_arguments[@]}" --preserve-metadata=entitlements "$helper"
  fi
done
codesign "${codesign_arguments[@]}" "$app_path/Contents/Frameworks/Sparkle.framework"
codesign "${codesign_arguments[@]}" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

echo "$app_path"
