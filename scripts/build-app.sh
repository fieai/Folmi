#!/bin/zsh
set -euo pipefail

app_root="${0:A:h:h}"
cd "$app_root"
relaunch=0
variant=""
for argument in "$@"; do
  case "$argument" in
    --preview|--navigation-preview|--editor-preview)
      if [[ -n "$variant" ]]; then print -u2 '构建脚本最多接受一个预览参数'; exit 1; fi
      variant="$argument" ;;
    --relaunch) relaunch=1 ;;
    --help|-h)
      print '用法：./scripts/build-app.sh [--preview|--navigation-preview|--editor-preview] [--relaunch]'
      print '构建 Apple Silicon / macOS 14+ 本地测试 App（有 Apple Development 证书时用它签名，否则 ad-hoc）。'
      print -- '--relaunch  打包完退出正在运行的这个 App（有没保存的内容会先问你），再打开新版。'
      exit 0 ;;
    *) print -u2 "未知参数：$argument"; exit 1 ;;
  esac
done
set -- ${variant:+"$variant"}
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
# Release binaries keep their local symbols (over half of Folmi's size); crash reports still symbolicate from
# the .dSYM next to the build products. Strip before signing.
/usr/bin/strip -x "$app_dir/Contents/MacOS/Folmi" "$app_dir/Contents/MacOS/folmi-hook"
/usr/bin/install -m 644 "$app_icon" "$app_dir/Contents/Resources/Folmi.icns"
for resource_bundle in "$binary_dir"/SwiftTerm_*.bundle(N); do
  if [[ -d "$app_dir/${resource_bundle:t}" ]]; then
    /bin/rm -rf "$app_dir/${resource_bundle:t}"
  fi
  /usr/bin/ditto "$resource_bundle" "$app_dir/Contents/Resources/${resource_bundle:t}"
done
# The app target's reader assets, fonts and Folmi brand resources. Only Folmi_Folmi.bundle: a glob would also
# pick up bundles that older target names left in the build folder.
resource_bundle="$binary_dir/Folmi_Folmi.bundle"
if [[ ! -d "$resource_bundle" ]]; then print -u2 "缺少资源包：$resource_bundle"; exit 1; fi
/usr/bin/ditto "$resource_bundle" "$app_dir/Contents/Resources/${resource_bundle:t}"
# Brand/ also holds the icon sources and exports for docs/brand; the app reads only the menu bar mark and the
# small mascots (AppResources.swift, TerrazzoParticles.swift). The Dock icon is the Folmi.icns installed above.
brand_dir="$(/usr/bin/find "$app_dir/Contents/Resources/${resource_bundle:t}" -type d -name Brand -print -quit)"
if [[ -n "$brand_dir" ]]; then
  for entry in "$brand_dir"/*(N); do
    [[ "${entry:t}" == (MenuBar|UI) ]] || /bin/rm -rf "$entry"
  done
fi
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
  <key>NSServices</key><array><dict>
    <key>NSMenuItem</key><dict><key>default</key><string>用 Folmi 打开</string></dict>
    <key>NSMessage</key><string>openFolder</string>
    <key>NSPortName</key><string>Folmi</string>
    <key>NSRequiredContext</key><dict/>
    <key>NSSendFileTypes</key><array><string>public.folder</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>None</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string></array>
  </dict></array>
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
# Finder's right-click 「用 Folmi 打开」; preview builds name themselves so the two entries can be told apart.
if [[ "$bundle_title" != Folmi ]]; then
  /usr/libexec/PlistBuddy -c "Set :NSServices:0:NSMenuItem:default 用 ${bundle_title}打开" "$app_dir/Contents/Info.plist"
fi
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
# Register the bundle and refresh the services list now, so the Finder entry appears without a logout.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_destination" || true
/System/Library/CoreServices/pbs -update || true
print "已生成：$app_destination（签名：$sign_identity）"

# The running copy keeps its old binary (it was moved to dist/legacy), so a rebuild only shows after a restart.
# Quit goes through the app like ⌘Q: unsaved edits still get their prompt, and cancelling it keeps the old copy open.
if (( relaunch )); then
  is_running() { [[ "$(/usr/bin/osascript -e "application id \"$bundle_id\" is running" 2>/dev/null)" == true ]] }
  if is_running; then
    print "退出正在运行的 $bundle_title …"
    if ! /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1; then
      print -u2 "没能让 $bundle_title 退出（可能要在「系统设置 › 隐私与安全性 › 自动化」里允许终端控制它）。请手动退出后打开：$app_destination"
      exit 1
    fi
    # Up to a minute, for a save prompt to be answered.
    for _ in {1..120}; do is_running || break; sleep 0.5; done
    if is_running; then
      print -u2 "$bundle_title 还开着（可能取消了退出），没有打开新版。退出后打开：$app_destination"
      exit 1
    fi
  fi
  /usr/bin/open "$app_destination"
  print "已打开新版 $bundle_title"
fi
