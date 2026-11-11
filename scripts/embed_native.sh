#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_root/native/lib"
if [[ ! -f "$source_dir/libf7zip.dylib" || ! -f "$source_dir/7z.so" || ! -f "$source_dir/f7zip" || ! -f "$source_dir/7z-x86.sfx" ]]; then
  echo 'error: 原生引擎尚未构建。请先运行 python3 scripts/build_native.py'
  exit 1
fi
destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/F7Zip"
mkdir -p "$destination"
cp "$source_dir/libf7zip.dylib" "$source_dir/7z.so" "$destination/"
# PE 模块置于资源目录，避免 macOS 将其作为嵌套原生代码检查签名。
rm -f "$destination/7z-x86.sfx"
sfx_resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/F7Zip"
mkdir -p "$sfx_resources"
cp "$source_dir/7z-x86.sfx" "$sfx_resources/"
mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/F7ZipLicenses"
cp "$source_dir/licenses/"* "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/F7ZipLicenses/"
rm -rf "$destination/licenses"
for library in "$destination/libf7zip.dylib" "$destination/7z.so"; do
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$library"
done
cli="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/f7zip-cli"
cp "$source_dir/f7zip" "$cli"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$cli"
