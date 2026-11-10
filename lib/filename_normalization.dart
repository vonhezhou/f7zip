enum FilenameNormalization {
  preserve('保留原样'),
  nfc('NFC · 组合形式'),
  nfd('NFD · 分解形式');

  const FilenameNormalization(this.label);
  final String label;
}
