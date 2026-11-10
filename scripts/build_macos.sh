#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/build_native.py
flutter pub get
flutter build macos --release
# Flutter 完成构建后统一密封框架与应用，避免增量资源更新使签名失效。
codesign --force --sign - --timestamp=none build/macos/Build/Products/Release/F7Zip.app/Contents/Frameworks/App.framework
codesign --force --sign - --timestamp=none --entitlements macos/Runner/Release.entitlements build/macos/Build/Products/Release/F7Zip.app
codesign --verify --deep --strict build/macos/Build/Products/Release/F7Zip.app
python3 scripts/package_sources.py
mkdir -p dist
# ditto 保留完整应用包和资源布局。
ditto build/macos/Build/Products/Release/F7Zip.app dist/F7Zip.app
codesign --verify --deep --strict dist/F7Zip.app
printf '\n可直接运行的应用\n%s/dist/F7Zip.app\n' "$PWD"
