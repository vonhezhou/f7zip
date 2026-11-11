# ALZ / EGG 解码器评估

核对日期为 2026-11-11。用户明确决定暂缓 ALZ / EGG 的识别、浏览、解压和创建，第 29 项已移出近期计划。收到真实用户样本或明确面向韩国用户时可重新评估，接入须经用户重新确认。本文保留候选库与许可证调查，供后续需求评审使用。

## 已核对的候选

| 候选 | 许可证与版本事实 | 覆盖与接入影响 |
| --- | --- | --- |
| alkegi/unalz | 主库 MIT，0.2.1，要求 Rust 1.88+，最新提交为 2026-08-02 的 `30b4ad40c5452c686df69b3b45554de3073e57a1` | 上游声明支持 ALZ Store、Deflate、变体 Bzip2、ZipCrypto、分卷、CP949 和 CRC。需要固定 Cargo 依赖并审核传递许可证。 |
| alkegi/unegg | 主库 MIT，0.2.1，要求 Rust 1.88+，最新提交为 2026-08-02 的 `9929009ca4d010e8cd88bb796f7a1868162026d4` | 上游声明支持 EGG Store、Deflate、Bzip2、LZMA、AZO，以及加密、固实和分卷。需要新的 Rust 辅助程序及真实样本验收。 |
| alkegi/libazo | 主库 MIT，0.1.1，要求 Rust 1.85+ | unegg 的 AZO 依赖，README 列出 xunazo 为参考。xunazo 的许可证允许商业使用、修改及分发，要求保留来源和修改标识。分发时需保留相关通知。 |
| MacPaw/XADMaster | LGPL-2.1-or-later，最新提交为 2026-09-21 的 `7cb9ee0abbb163f261e4cb74501e15067032319c` | 树中存在 `XADALZipParser`，未发现 EGG 解析器。Objective-C 路线可覆盖 ALZ，需引入其解析、流与解码依赖，并处理 LGPL 对应源码与替换条件。 |
| 旧版 UnEGG Linux SDK 0.5 | ESTsoft 自定义许可证 | 许可证要求商业用途获得公司授权，限制修改 AZO，并要求随源码和文档分发协议。该许可证与当前 MIT 项目的分发约定存在需要另行确定的使用条件。 |

以上覆盖能力来自上游文档，尚未在 F7Zip 中完成兼容性、安全边界或维护质量验收。版本时间只能证明近期活动，真实损坏样本和持续回归仍需补齐。

## 后续接入候选

后续重启评估时，可考虑独立 Rust 辅助程序，固定 `unalz` / `unegg` 版本及 Cargo.lock。该方案的开发和 CI 需要 Rust 1.88+，最终应用携带编译完成的程序，用户运行时沿用应用包内依赖。调查时环境的 PATH 中未检测到 Cargo。

辅助程序负责受限解码，主进程沿用现有路径检查、私有暂存、来源版本、排他发布与失败清理。密码通过私有输入通道传递，避免出现在命令行参数中。辅助程序取消、退出状态、输出大小、进程生命周期和签名均需纳入测试。浏览和测试同样要受展开预算限制。

原生工具链路线可先评估 ALZ，EGG 继续寻找相应实现。重新启动时，根据样本覆盖、维护成本与许可证核对结果选择接入方式。

## 接入后的验收范围

- 固定源包、摘要和依赖锁，核对全部传递许可证并纳入对应源码分发。
- 使用具有明确再分发许可的真实 ALZ / EGG 样本，核对多种压缩方法、Unicode、CP949、空目录、CRC 及独立工具输出。
- 覆盖越界、规范等价和重复路径、特殊文件、链接、超限及损坏输入。
- 覆盖选中解压、已有目标、源变化、运行中取消、失败清理和重试，验证辅助程序结束后没有后台进程或暂存残留。
- 加密、固实和分卷能力按实际验收结果记录，界面和文档与已通过范围一致。

## 依据

- [unalz 源码与声明](https://github.com/alkegi/unalz/tree/30b4ad40c5452c686df69b3b45554de3073e57a1)
- [unegg 源码与声明](https://github.com/alkegi/unegg/tree/9929009ca4d010e8cd88bb796f7a1868162026d4)
- [libazo 许可证](https://github.com/alkegi/libazo/blob/master/LICENSE)
- [xunazo 许可证](https://github.com/kippler/xunazo/blob/master/LICENSE)
- [XADMaster ALZ 解析器](https://github.com/MacPaw/XADMaster/blob/7cb9ee0abbb163f261e4cb74501e15067032319c/XADALZipParser.m)
- [旧版 UnEGG SDK 许可证](https://github.com/dterracino/UnEgg/blob/master/Source/unegg/doc/license.txt)
