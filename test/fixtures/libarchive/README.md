# RAR 分卷测试样本

这些 uuencode 样本来自 libarchive 官方测试套件，用于验证 RAR / RAR5 跨卷读取、固实归档、缺卷与损坏保护。测试解码到私有临时目录，其中旧 RAR 样本预期得到 20111 字节的 `LibarchiveAddingTest.html`，CRC32 为 `5E05A663`。

| 文件 | 官方 Git blob SHA-1 |
| --- | --- |
| test_rar_multivolume_single_file.part1.rar.uu | b2afdf152a484e6214dd6d818272d9859ddefc5f |
| test_rar_multivolume_single_file.part2.rar.uu | 615698bdefb317abfd6ba4c7d0d1bb28de9388dc |
| test_rar_multivolume_single_file.part3.rar.uu | 63c984782e1de7826f308b94a773d03583d5e54c |
| test_read_format_rar5_multiarchive_solid.part01.rar.uu | af4addf62d6960dc2c5a5133401fe503aee41e88 |
| test_read_format_rar5_multiarchive_solid.part02.rar.uu | 1d77567e3e2b9b846b1688afc0b997c453735e71 |
| test_read_format_rar5_multiarchive_solid.part03.rar.uu | 4ec0e551fd1f324a7136916f182d97ebc751ff8b |
| test_read_format_rar5_multiarchive_solid.part04.rar.uu | efba21d5076b5bea813451adb78e3dce6cdb4d0e |

下载时逐个核对了 Git blob 摘要，许可证保留在同目录的 `COPYING`。样本仅用于测试。

- [官方样本目录](https://github.com/libarchive/libarchive/tree/master/libarchive/test)
- [官方预期结果](https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar.c)
- [RAR5 固实归档的官方校验值](https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar5.c)
