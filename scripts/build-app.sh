#!/bin/zsh
set -euo pipefail

app_root="${0:A:h:h}"
cd "$app_root"
case "${1:-}" in
  ""|--preview|--navigation-preview|--editor-preview) ;;
  --help|-h)
    print '用法：./scripts/build-app.sh [--preview|--navigation-preview|--editor-preview]'
    print '构建 Apple Silicon / macOS 14+ 本地测试 App（有 Apple Development 证书时用它签名，否则 ad-hoc）。'
    exit 0 ;;
  *) print -u2 "未知参数：$1"; exit 1 ;;
esac
if (( $# > 1 )); then print -u2 '构建脚本最多接受一个预览参数'; exit 1; fi
app_icon="$app_root/Sources/Folmi/Resources/Brand/Folmi.icns"
if [[ ! -s "$app_icon" ]]; then
  print -u2 "缺少 App 图标：$app_icon"
  exit 1
fi
swift build -c release --arch arm64 --product Folmi
swift build -c release --arch arm64 --product folmi-hook
binary_dir="$(swift build -c release --arch arm64 --show-bin-path)"
bundle_name="Folmi"
bundle_id="local.folmi.app"
bundle_title="Folmi"
if [[ "${1:-}" == "--preview" ]]; then
  bundle_name="Folmi-Preview"
  bundle_id="local.folmi.preview"
  bundle_title="Folmi 预览"
fi
if [[ "${1:-}" == "--navigation-preview" ]]; then
  bundle_name="Folmi-NavigationPreview"
  bundle_id="local.folmi.navigationpreview"
  bundle_title="Folmi 导航预览"
fi
if [[ "${1:-}" == "--editor-preview" ]]; then
  bundle_name="Folmi-EditorPreview"
  bundle_id="local.folmi.editorpreview"
  bundle_title="Folmi 编辑预览"
fi
mkdir -p "$app_root/dist"
app_destination="$app_root/dist/$bundle_name.app"
staging_root="$(mktemp -d "$app_root/dist/.folmi-build.XXXXXX")"
trap '/bin/rm -rf "$staging_root"' EXIT
app_dir="$staging_root/$bundle_name.app"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$binary_dir/Folmi" "$app_dir/Contents/MacOS/Folmi"
cp "$binary_dir/folmi-hook" "$app_dir/Contents/MacOS/folmi-hook"
/usr/bin/install -m 644 "$app_icon" "$app_dir/Contents/Resources/Folmi.icns"
for resource_bundle in "$binary_dir"/SwiftTerm_*.bundle(N); do
  if [[ -d "$app_dir/${resource_bundle:t}" ]]; then
    /bin/rm -rf "$app_dir/${resource_bundle:t}"
  fi
  /usr/bin/ditto "$resource_bundle" "$app_dir/Contents/Resources/${resource_bundle:t}"
done
# The app target's reader assets, fonts and Folmi brand resources.
for resource_bundle in "$binary_dir"/Folmi_*.bundle(N); do
  /bin/rm -rf "$app_dir/Contents/Resources/${resource_bundle:t}"
  /usr/bin/ditto "$resource_bundle" "$app_dir/Contents/Resources/${resource_bundle:t}"
done
/usr/bin/install -m 644 "$app_root/.build/checkouts/SwiftTerm/LICENSE" "$app_dir/Contents/Resources/SwiftTerm-LICENSE.txt"
/usr/bin/install -m 644 "$app_root/licenses/KaTeX-LICENSE.txt" "$app_dir/Contents/Resources/KaTeX-LICENSE.txt"
/usr/bin/install -m 644 "$app_root/licenses/Mermaid-LICENSE.txt" "$app_dir/Contents/Resources/Mermaid-LICENSE.txt"
/bin/mkdir -p "$app_dir/Contents/Resources/FusionPixel-LICENSES"
/usr/bin/install -m 644 "$app_root"/licenses/FusionPixel/* "$app_dir/Contents/Resources/FusionPixel-LICENSES/"
/usr/bin/install -m 644 "$app_root/licenses/OneDarkPro-LICENSE.txt" "$app_dir/Contents/Resources/OneDarkPro-LICENSE.txt"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Folmi</string>
  <key>CFBundleIdentifier</key><string>local.folmi.app</string>
  <key>CFBundleName</key><string>Folmi</string>
  <key>CFBundleDisplayName</key><string>Folmi</string>
  <key>CFBundleIconFile</key><string>Folmi.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.0</string>
  <key>CFBundleVersion</key><string>0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>local.folmi.link</string>
    <key>CFBundleURLSchemes</key><array><string>folmi</string></array>
  </dict></array>
</dict></plist>
PLIST
version="$(<"$app_root/VERSION")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${version//./}" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $bundle_title" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $bundle_title" "$app_dir/Contents/Info.plist"
# Ad-hoc signatures are pinned to the cdhash, so macOS forgets folder-access grants on every rebuild.
# Prefer a stable Apple Development identity; set FOLMI_SIGN_IDENTITY=- to force ad-hoc.
sign_identity="${FOLMI_SIGN_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development:/ { print $2; exit }')}"
sign_identity="${sign_identity:--}"
# Sign embedded Mach-O code first; --deep is reserved for verification.
while IFS= read -r -d '' code_file; do
  if [[ "$(/usr/bin/file -b "$code_file")" == *Mach-O* ]]; then
    if [[ "$(/usr/bin/lipo -archs "$code_file")" != arm64 ]]; then
      print -u2 "构建包含非 arm64 二进制：$code_file"; exit 1
    fi
    /usr/bin/codesign --force --sign "$sign_identity" "$code_file"
  fi
done < <(/usr/bin/find "$app_dir/Contents" -type f -print0)
/usr/bin/codesign --force --sign "$sign_identity" "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
# Replace the whole generated bundle so obsolete executables/resources cannot survive a rename.
if [[ -e "$app_destination" ]]; then
  mkdir -p "$app_root/dist/legacy"
  archived_app="$app_root/dist/legacy/$bundle_name-$(date -u +%Y%m%dT%H%M%SZ).app"
  while [[ -e "$archived_app" ]]; do archived_app="${archived_app%.app}-$RANDOM.app"; done
  mv "$app_destination" "$archived_app"
fi
mv "$app_dir" "$app_destination"
print "已生成：$app_destination（签名：$sign_identity）"
