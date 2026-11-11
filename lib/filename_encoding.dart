enum FilenameEncoding {
  autoDetect(0, '自动检测'),
  utf8(65001, 'UTF-8'),
  gb18030(54936, '简体中文 GB18030'),
  gbk(936, '简体中文 Windows CP936 / GBK'),
  big5(950, '繁体中文 Big5'),
  shiftJis(932, '日文 Shift-JIS'),
  korean(949, '韩文 CP949'),
  western(1252, '西欧 Windows-1252'),
  dos(437, 'DOS CP437');

  const FilenameEncoding(this.codePage, this.label);
  final int codePage;
  final String label;
}
