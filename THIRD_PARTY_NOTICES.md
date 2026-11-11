# 第三方组件

F7Zip 自有代码使用 MIT。下列组件继续适用各自许可证。

| 组件 | 固定版本 | 许可证 | 源码 |
| --- | --- | --- | --- |
| 7-Zip | 26.06 | LGPL-2.1-or-later、BSD、unRAR 限制 | https://github.com/ip7z/7zip/releases/download/26.06/7z2606-src.tar.xz |
| 7-Zip 普通 GUI SFX 模块 | 26.06，Windows x86 | LGPL-2.1-or-later | 官方 `7z2606-x64.exe` 内的 `7z.sfx`，对应源码同上 |
| bit7z | v4.0.10，提交 `0f03717920442abcdba80183534931c867feb9c0` | MPL-2.0 | https://github.com/rikyoz/bit7z/tree/0f03717920442abcdba80183534931c867feb9c0 |
| libarchive RAR / RAR5 测试样本 | 见 `test/fixtures/libarchive/README.md` 中的 Git blob 摘要 | BSD-2-Clause，许可证见同目录 `COPYING` | https://github.com/libarchive/libarchive/tree/master/libarchive/test |
| Flutter / Dart | 以构建环境和 `pubspec.lock` 为准 | BSD-3-Clause | https://github.com/flutter/flutter |
| desktop_drop | 以 `pubspec.lock` 为准 | MIT | https://pub.dev/packages/desktop_drop |
| ffi / path / crypto | 以 `pubspec.lock` 为准 | BSD-3-Clause | https://pub.dev/publishers/dart.dev/packages |

7-Zip 构建时通过 `scripts/build_native.py` 应用 ZIP 文件名编码、注释保留及 RAR 注释读取补充，转换实现位于 `native/7zip_codepage.hpp` 和 `native/7zip_rar_comments.hpp`。源码包保留经校验的原始 7-Zip 归档、补充代码与可重复应用的构建步骤。bit7z 构建时以 `native/bit7z_genericinputitem.cpp` 替换原 `genericinputitem.cpp`，补齐 TAR 写入的 POSIX 权限属性；以 `native/bit7z_stringutil.cpp` 替换原 `stringutil.cpp`，兼容 POSIX 中的 UTF-16 代理对与 UTF-32 字符串。这些修改文件保留原版权声明和 MPL-2.0 许可证，并随源码包分发。桥接层位于 `native/f7zip.cpp` 与 `native/zip_encoding.mm`。7-Zip 共享库在运行时动态加载，bit7z 编译进桥接动态库。

应用包在 `Contents/Resources/F7ZipLicenses` 中保留 7-Zip、LGPL 和 bit7z 的许可证全文。Flutter 依赖许可证由 Flutter 的构建流程收集到应用资源中。运行 `scripts/build_macos.sh` 时，还会生成包含项目代码与固定版本第三方源码的 `dist/F7Zip-sources.tar.gz`。重新分发时应同时提供对应源码与许可证。

SFX 模块保存在 `native/sfx/7z-x86.sfx`，来源、PE 架构与摘要见该目录的 `README.md`。构建与创建时验证固定摘要，应用资源中分发原模块，对应完整源码与许可证随源码包提供。bit7z 字符串桥接为 SFX 任务增加 UTF-16 密码作用域，沿用原 MPL-2.0 声明。

unRAR 限制见 7-Zip 的 `DOC/unRarLicense.txt`。本应用支持 RAR 读取与解压，支持创建 ZIP、ZIPX、7z、Windows SFX、存储型 WIM、TAR、GZIP、XZ、BZIP2 及复合 TAR 归档。

F7Zip 使用自行实现的界面和图标，未包含 Bandizip 的代码、图标或界面素材。
