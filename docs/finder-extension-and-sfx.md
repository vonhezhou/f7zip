# Finder 扩展与 Windows SFX 评估

评估日期为 2026-11-11，对应 TASKS.md 第 30 项。核对范围包括现有代码、Apple / Microsoft / 7-Zip 文档，以及临时目录中的 SFX 容器试验。

F7Zip 面向跨平台桌面用户，当前开发与验证优先 macOS。本文的实测范围对应当前开发阶段，功能价值按跨平台产品需求评估。

## 接入进展

2026-11-11 用户决定支持 SFX 后，已接入当前 macOS 实现的普通数据创建，以及 7z / ZIP / RAR / RAR5 单卷 SFX 归档式读取。新建窗口、预设和 CLI 使用固定的官方普通 GUI 模块，模块实际架构经 PE 头验证为 x86。模块来自官方 x64 安装包，摘要及许可证见 `native/sfx/README.md`。当前实现按模块能力提供 Copy、LZMA2、LZMA、PPMd 和 AES，创建前核对 Windows 名称及输入类型，创建后验证载荷并保留原子发布保护。

常规归档的密码转换沿用已有行为，SFX 任务采用与 Windows 一致的 UTF-16 契约。四种算法及含表情密码的载荷已与官方独立 7zz 完成双向核对。读取使用明确的内层格式探测，SFX 以只读方式浏览。此前两例自动识别失败记录保留用于说明接入前的现象。

当前环境未检测到可用的 Windows 虚拟机或 Wine，运行验收范围为 macOS 上的创建、解析和数据互操作。Windows GUI 执行、目标架构兼容、长路径、安全软件和签名交付仍需在目标环境验证。完整使用范围见 README 的“Windows 自解压包”。

## 结论与使用范围

| 功能 | 实际用途 | 接入与发布成本 | 后续启动条件 |
| --- | --- | --- | --- |
| Finder 工具栏扩展 | 在 Finder 常驻工具栏中打开 F7Zip、发起压缩或解压，提高高频操作的可发现性 | 新增 Finder Sync 扩展 target、沙盒权限、主应用通信、系统启用与升级验收，配套分发签名 | 收到明确的工具栏使用需求，确定按钮行为及目录覆盖范围 |
| SFX 归档读取 | 在各平台浏览、测试和解压 Windows 自解压包中的归档载荷 | 补齐格式识别、扫描预算、只读属性和外部打开边界，复用现有解压保护 | 建议作为跨平台兼容性增强优先排期，首批按 7z / ZIP 样本验收 |
| Windows 普通数据 SFX 创建 | Windows 版本本机生成自解压 EXE，以及其他桌面版本向 Windows 接收方交付自解压包 | 固定普通解压模块、支持算法和目标架构，完成 Windows 运行验收，提供签名交付说明 | 建议保留为中优先级高级功能候选，按跨平台交付需求排期 |
| 安装型 SFX 创建 | 解压后运行安装程序或指定命令 | 配置与命令执行、权限、签名和安装生命周期的验收成本较高 | 具体安装交付需求出现后单独评估 |

Finder 工具栏可作为 macOS 平台的易用性增强。重新评估后，SFX 值得纳入跨平台规划，建议顺序为归档读取、Windows 普通数据自解压创建，再按具体需求考虑安装型能力。读取兼容性可以在当前 macOS 阶段推进，Windows EXE 的导出可以由各宿主平台生成，发布验收覆盖 Windows 接收端。创建入口的优先级由用户交付需求、安全行为与维护成本决定。

## Finder 工具栏扩展

### 现有入口与可复用能力

当前 `AppDelegate` 使用 NSServices 接收 Finder 选中文件，经 `enqueue(action:paths:)` 交给 Dart 队列，支持冷启动。现有服务覆盖打开、配置压缩、快捷 ZIP、原地解压和选择目录解压。工具栏入口可复用这些任务、密码和冲突处理能力。

Apple 的 Finder Sync 扩展提供 `toolbarItemName`、`toolbarItemImage`、`toolbarItemToolTip` 和 `menuForMenuKind`，通过 `com.apple.FinderSync` 扩展点接入。工具栏按钮可在被观察目录之外出现。Apple 指南限定 `selectedItemURLs` / `targetedURL` 的有效调用时机，并说明在被观察目录之外可能返回空值，因此应在目标 macOS 版本实测选中项覆盖。

建议首版按钮提供打开主窗口及由主应用弹出选择面板的压缩、解压入口。若加入直接处理 Finder 选中项的操作，应明确被观察目录设置与无有效选择时的交互。Finder Sync 官方定位为文件同步状态与控制，采用其通用工具栏能力时需要保持职责精简。[Apple Finder Sync 指南](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)

### 进程与文件访问

扩展应快速生成菜单并将请求交给主应用，压缩引擎和任务队列放在主应用中。系统可为 Finder 和打开 / 保存面板启动多个扩展实例，通信需校验 action、文件 URL 和请求标识，并按既有队列规则协调重复请求。

Xcode 的 macOS 扩展模板默认配置 App Sandbox 和用户选中文件只读权限，实际写入及访问方式应按所选入口配置。若采用 App Groups 共享配置或请求队列，主应用与扩展需配置同一组，并验证共享容器和文件访问授权。Apple 要求扩展控制启动时间和资源占用。[Apple 扩展创建指南](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)

### 签名与分发

当前 `scripts/build_macos.sh` 采用 ad hoc 签名，检查到的应用 `TeamIdentifier` 为未设置，`Release.entitlements` 中主应用 App Sandbox 为关闭。这些是当前本地构建事实。

正式直接分发可采用 Developer ID Application，配置扩展 bundle ID、所需 entitlements 和相应分发配置，按嵌套代码从内到外签名，随后公证并装订票据。应用包将扩展嵌入 `Contents/PlugIns`。启用操作由用户在系统扩展管理中完成。App Store 路线另行验证其分发配置、沙盒与授权要求。[Apple 分发签名](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac) · [Apple 公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

实施验收需覆盖扩展启用与停用、Finder 重启、多窗口、多个扩展实例、无选择、不同目录、冷启动、升级、应用移动、文件访问授权和请求去重。当前已完成文档与代码核对，Finder 扩展运行及正式分发签名待实施时验收。

## Windows 自解压包

### 跨平台价值与风险

Windows 用户在接收方尚未部署相应解压工具、需在受控环境分发资料或携带固定解码器时，有使用普通数据 SFX 的价值。其他系统上的 F7Zip 也可生成同一 Windows 目标包，导出功能与宿主端 UI 的移植进度可以分别安排。

SFX 产物带有具体的运行系统与处理器架构。Windows PE、macOS 应用包及 Linux 可执行文件各有运行与发行机制，当前证据支持先评估 Windows EXE。macOS / Linux 原生自解压格式可在相应用户需求明确后核对。

SFX 包含可执行代码和归档载荷，运行 EXE 会执行解压模块。普通数据模块可以在解压完成后结束，安装型模块还能执行后续命令。风险评估应分别覆盖模块自身、恶意载荷、自动执行行为与解析器漏洞。以归档解析器读取载荷时，仍需处理路径越界、重复名称、解压炸弹、特殊文件及外部打开行为。

### 同类产品的选择

7-Zip 官方提供 7z 自解压能力，源码中普通 GUI / 控制台解压模块和安装型模块各有入口。Bandizip Windows 提供 SFX 创建参数及固定 SFX 模块，并公开说明该模块可能被杀毒软件误报。[7-Zip 官方功能](https://www.7-zip.org/) · [Bandizip 创建参数](https://www.bandisoft.com/bandizip/help/parameter/) · [Bandizip SFX 误报说明](https://www.bandisoft.com/bandizip/help/bdzsfx-x86-sfx/)

Bandizip macOS 产品页明确列出 SFX(EXE) 解压，CLI 文档另列 EXE 创建参数，两处范围表述存在差异。其 macOS 创建能力仍需实机确认，本次优先级建议主要依据已核对的 Windows 功能。[Bandizip macOS 产品页](https://www.bandisoft.com/bandizip.mac/) · [macOS CLI 参数](https://en.bandisoft.com/bandizip.mac/help/parameter/)

### 建议的首批边界

- 归档读取通过明确的“用 F7Zip 打开归档”入口进入，按结构识别首批 7z / ZIP 载荷。识别失败时返回格式或损坏错误，交互停留在归档流程。
- 格式探测采用有界扫描和尝试预算，浏览、测试、解压沿用源版本、资源限制、路径检查、冲突策略、取消与排他发布。首批以只读归档处理带可执行前缀的容器，修改能力需验证封装和签名后另行评估。
- 当前“查看 / 编辑”会提取文件再交给系统关联程序打开。Windows 适配时，包内可执行文件及脚本的外部启动需有明确的用户动作与风险提示，并验证下载来源标记的传播。SFX 容器浏览本身走归档解析路径。
- 普通数据创建采用固定来源、版本和摘要的解压后结束模块，显式选择“Windows 自解压包（EXE）”、目标架构和输出位置。算法、字典、固实块和加密设置限定在模块实测支持范围内。
- 创建在私有暂存中生成，发布前重新测试载荷、检查源版本并排他发布，失败和取消时清理暂存。安装命令与解压后启动属于安装型能力的独立配置及验收范围。

### 模块选择与封装

7-Zip 源码提供普通 GUI 模块 `7z.sfx`、控制台模块 `7zCon.sfx`，以及安装用途的 SFX 模块。普通数据交付优先评估 GUI 解压模块，按固定模块支持的算法、加密和目标架构生成 7z 载荷，再拼接成 PE 可执行文件。

官方 LZMA SDK 26.06 中的 `7zSD.sfx`、`7zS2.sfx` 面向安装用途。SDK 的 `DOC/installer.txt` 说明前者可读取安装配置并默认运行 `setup.exe`，后者会选择解出的文件执行。小型模块还将固实块解码到内存，其内存预算取决于最大固实块。数据归档入口选用模块时，应将自动执行、算法支持与解码内存列为明确的产品行为。[7-Zip 源码说明](https://github.com/ip7z/7zip/blob/26.06/DOC/readme.txt) · [LZMA SDK](https://www.7-zip.org/sdk.html)

许可需按实际选择的包和模块核对。官方 LZMA SDK 声明为 public domain，完整 7-Zip 使用 LGPL 及相关逐文件许可。现有完整源码分发可作为对应源码流程基础，新增模块需固定来源、版本和摘要，并保留适用通知。

### 本次容器试验

所有试验文件位于临时目录。下载的官方包按 GitHub Release 提供的 SHA-256 核对。

| 官方包 | SHA-256 |
| --- | --- |
| `lzma2606.7z` | `1d9da340870b12712e9068be178a4436fbad785486b62aed6e2aa88ea1e3bb65` |
| `7z2606-extra.7z` | `396c180f12d2247c24b0b1fcd482c6fc2a2700f61211ffede1061dd971f5e104` |
| `7z2606-x64.exe` | `9b697f65ecc2d9b0152f5ee96d72dde522a7827690349d9307935dacf40f42ec` |
| `7z2606-mac.tar.xz` | `b6f17920b4240940461dac8ef4009891881ac44d2a5ead625ede2ec8472185dd` |

SDK 样本中的两个模块均为 x86 PE，不能据此推断其他架构的运行兼容性。Extra 包中未找到 `.sfx` 模块，普通 GUI 模块仍需从对应发行包或构建产物获取。

使用 F7Zip CLI 创建含中文与表情文件名的 LZMA2 载荷，分别拼接两个 SDK 模块，得到以下结果。

| 容器 | 模块大小 / 载荷偏移 | 官方 macOS 7zz 26.06 | F7Zip 当前 CLI |
| --- | --- | --- | --- |
| `7zS2.sfx` + 7z 载荷 | 35328 字节 | 完整性测试、解压及字节一致性通过 | 自动测试与解压返回打开归档失败，退出 1 |
| `7zSD.sfx` + 7z 载荷 | 129024 字节 | 完整性测试、解压及字节一致性通过 | 自动测试与解压返回打开归档失败，退出 1 |

另以 F7Zip CLI 尝试解包官方 Windows 安装程序，同样返回打开归档失败。上一版评估对扫描限制的归因需要更正。`BitArchiveReader` 的常规构造函数使用 `ArchiveStartOffset::None`，`FileStart` 是可选分支。自动识别实现把 `.exe` 扩展名和 MZ 签名映射到 PE，并明确注明尚未区分 7z SFX。这条识别路径需要补齐内层归档探测。[bit7z 构造函数](https://github.com/rikyoz/bit7z/blob/0f03717920442abcdba80183534931c867feb9c0/src/bitarchivereader.cpp) · [打开流程及默认参数](https://github.com/rikyoz/bit7z/blob/0f03717920442abcdba80183534931c867feb9c0/include/bit7z/bitinputarchive.hpp) · [自动格式识别](https://github.com/rikyoz/bit7z/blob/0f03717920442abcdba80183534931c867feb9c0/src/internal/formatdetect.cpp)

本次追加临时 C++ 探针，链接当前 `libf7zip.dylib`，使用 MZ 签名的 512 字节合成前缀与真实 7z 载荷。自动识别打开失败，显式指定 `BitFormat::SevenZip` 后，完整性测试、解压和中文表情文件名的字节核对通过，临时文件已回收。该结果验证了此合成样本的内层格式打开路径，真实 Windows 模块及其他 SFX 类型仍需样本回归。

上述成功结果验证了容器布局及载荷内容。Windows 模块执行、安装行为、不同架构和签名后的可运行性需在 Windows 环境验证。本次已执行的测试均为 macOS 上的文件解析。

### Windows 签名与交付

F7Zip 应用的发行签名与用户生成的 SFX 产物签名各有生命周期。导出入口可以生成未签名 EXE，并告知目标环境可能出现的信誉提示或策略阻止。签名交付作为可选发布流程，用户需要时对最终产物使用自身签名身份，私钥由用户的签名工具或受控服务管理。

Authenticode 流程顺序为生成载荷、拼接模块及配置、签名和时间戳、验证、分发。每个用户载荷都会形成新的 EXE，验证对象应为最终文件。签名用于验证发布者与文件完整性，内容风险还需由目标系统的安全防护处理。[Microsoft SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool) · [Authenticode 时间戳](https://learn.microsoft.com/en-us/windows/win32/seccrypto/time-stamping-authenticode-signatures)

SmartScreen 还会评估文件与发布者信誉，应将带网络来源标记的新包纳入 Windows 下载及首次启动测试。企业收件政策和邮件附件类型限制也会影响自解压 EXE 的实际交付价值。[Microsoft SmartScreen 信誉](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)

Windows Smart App Control 或企业应用控制策略可能阻止未签名或信誉不足的包，即使签名有效，新生成的文件仍可能出现 SmartScreen 提示。产品说明应准确列出这些交付条件，生成后的完整性测试与目标系统运行验收分别记录。[Microsoft SmartScreen 与 Smart App Control 说明](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)

实施验收包括 Windows 目标架构、Unicode 文件名和密码的跨宿主一致性、长路径、保留设备名、ADS 路径、来源系统元数据、已有文件、取消、损坏载荷、磁盘不足、运行权限、源保留和签名后验证。普通数据模块解压后的结束行为也需在 Windows 确认。安装配置的执行行为随安装型能力单独验收。
