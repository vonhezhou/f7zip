#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="$PWD/dist/F7Zip.app"
install_dir="${1:-$HOME/Applications}"
target_app="$install_dir/F7Zip.app"
if [[ ! -d "$source_app" ]]; then
  echo '请先运行 ./scripts/build_macos.sh'
  exit 1
fi
if [[ -e "$target_app" ]]; then
  installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist")"
  if [[ "$installed_id" != 'dev.von.f7zip' ]]; then
    echo '目标位置已有其他应用，请选择不同的安装目录。'
    exit 1
  fi
fi
mkdir -p "$install_dir"
staging_dir="$(mktemp -d "$install_dir/.f7zip-install-XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
ditto "$source_app" "$staging_dir/F7Zip.app"
codesign --verify --deep --strict "$staging_dir/F7Zip.app"
# 校验完成后原子替换，复制失败时现有安装保持完整。
swift - "$staging_dir/F7Zip.app" "$target_app" <<'SWIFT'
import Foundation
import Darwin
let source = CommandLine.arguments[1]
let target = CommandLine.arguments[2]
let flags = FileManager.default.fileExists(atPath: target) ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
if renamex_np(source, target, flags) != 0 {
  perror("安装 F7Zip 失败")
  exit(1)
}
SWIFT
codesign --verify --deep --strict "$target_app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target_app"
/System/Library/CoreServices/pbs -update
swift - <<'SWIFT'
import AppKit
NSUpdateDynamicServices()
for title in ["使用 F7Zip 打开", "压缩为 ZIP（F7Zip）", "使用 F7Zip 压缩", "解压到当前文件夹（F7Zip）", "解压到…（F7Zip）"] {
  NSSetShowsServicesMenuItem(title, true)
}
SWIFT
open "$target_app"
printf '\n已安装到 %s\nFinder 选中文件后，右键 → 服务 → F7Zip 打开、快捷 ZIP、配置压缩或解压菜单。\n' "$target_app"
