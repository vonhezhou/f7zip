# Windows 普通解压模块

`7z-x86.sfx` 为官方 7-Zip 26.06 Windows x64 安装包中的 `7z.sfx` 普通 GUI 解压模块，解压完成后结束。模块来源与摘要在构建时及每次创建 SFX 时校验。macOS 应用将模块保存于 `Contents/Resources/F7Zip/`，开发构建与独立 CLI 将模块放在引擎同目录。

- 官方安装包为 `7z2606-x64.exe`，SHA-256 为 `9b697f65ecc2d9b0152f5ee96d72dde522a7827690349d9307935dacf40f42ec`。
- 模块为 Windows x86 PE（源自 x64 安装包），214016 字节，SHA-256 为 `73af2700392aa92bc9342ae63844dfeed157d8d68bd356326a9bddb5e9e312d7`。
- 支持的编码器范围按对应源码确定为 Copy、LZMA、LZMA2、PPMd 及 7z AES，构建代码见 `CPP/7zip/Bundles/SFXWin/makefile`。
- 普通解压入口见 `CPP/7zip/Bundles/SFXWin/SfxWin.cpp`，本模块使用 7-Zip 的 LGPL 许可，许可证随应用分发，对应完整 26.06 源码包含在项目源码分发的 `third_party/7zip.tar.xz` 中。

复核或更新时，先校验官方安装包，显式按 7z 归档读取并提取其中的 `7z.sfx`，然后核对模块架构、源码、摘要、普通解压行为与许可证。更新本文件、构建校验与运行时校验，并完成 Windows 目标环境回归。

[官方 Release](https://github.com/ip7z/7zip/releases/tag/26.06) · [官方源码](https://github.com/ip7z/7zip/tree/26.06) · [许可证](https://www.7-zip.org/license.txt)
