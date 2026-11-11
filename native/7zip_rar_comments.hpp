// F7Zip 的旧 RAR 注释读取补充，复用 7-Zip 解码器并校验格式自带的 CRC。
// 本文件随原始 7-Zip 源码和可重复应用的构建步骤一同分发。
#pragma once
#include <iconv.h>
#include "../../../../C/7zCrc.h"
#include "../../Common/StreamObjects.h"
#include "../../Common/ProgressUtils.h"

struct F7RarCommentInfo {
    unsigned offset;
    unsigned packed;
    unsigned unpacked;
    UInt32 crc;
    Byte version;
    Byte method;
    bool modern;
    bool utf16;
};

static bool f7zipRarCommentInfo(const CByteBuffer &raw, F7RarCommentInfo &info) {
    if (raw.Size() < 13) return false;
    const Byte *header = raw;
    const unsigned headerSize = GetUi16(header + 5);
    info.modern = header[2] == 0x7a;
    info.utf16 = false;
    if (info.modern) {
        if (raw.Size() < 35 || headerSize < 35 || headerSize > raw.Size() || GetUi16(header + 26) != 3 ||
            memcmp(header + 32, "CMT", 3) != 0 || (GetUi16(header + 3) & 0x100)) return false;
        info.offset = headerSize;
        info.packed = GetUi32(header + 7);
        info.unpacked = GetUi32(header + 11);
        info.crc = GetUi32(header + 16);
        info.version = header[24];
        info.method = header[25];
        if (headerSize >= 39) info.utf16 = (GetUi32(header + 35) & 1) != 0;
    } else {
        if (header[2] != 0x75 || headerSize < 13 || headerSize > raw.Size()) return false;
        info.offset = 13;
        info.packed = headerSize - 13;
        info.unpacked = GetUi16(header + 7);
        info.crc = GetUi16(header + 11);
        info.version = header[9];
        info.method = header[10];
    }
    return info.unpacked <= (1u << 18) && info.packed <= (1u << 18) &&
        info.offset <= raw.Size() && info.packed <= raw.Size() - info.offset;
}

static UInt32 f7zipRarCommentCoder(const CByteBuffer &raw) {
    F7RarCommentInfo info;
    if (!f7zipRarCommentInfo(raw, info) || info.method == 0x30 || info.version < 15 || info.version > 40) return 0;
    return 0x40300 + (info.version < 20 ? 1 : info.version < 29 ? 2 : 3);
}

static bool f7zipReadRarComment(const CByteBuffer &raw, ICompressCoder *decoder, UString &text) {
    F7RarCommentInfo info;
    if (!f7zipRarCommentInfo(raw, info)) return false;
    const Byte *data = (const Byte *)raw + info.offset;
    const unsigned unpackedSize = info.unpacked;
    const unsigned packedSize = info.packed;
    CByteBuffer decoded(unpackedSize);
    if (info.method == 0x30) {
        if (packedSize != unpackedSize) return false;
        if (unpackedSize) memcpy(decoded, data, unpackedSize);
    } else {
        if (info.method < 0x31 || info.method > 0x35 || !decoder) return false;
        CMyComPtr<ICompressSetDecoderProperties2> properties;
        if (decoder->QueryInterface(IID_ICompressSetDecoderProperties2, (void **)&properties) != S_OK) return false;
        const Byte solid = 0;
        if (properties->SetDecoderProperties2(&solid, 1) != S_OK) return false;
        CMyComPtr2_Create<IInStream, CBufInStream> input;
        input->Init(data, packedSize);
        CMyComPtr2_Create<ISequentialOutStream, CBufPtrSeqOutStream> output;
        output->Init(decoded, unpackedSize);
        const UInt64 packed = packedSize;
        const UInt64 unpacked = unpackedSize;
        // RAR 解码器要求有效回调，此处只接收回调，不向空的外部进度对象转发。
        CMyComPtr2_Create<ICompressProgressInfo, CLocalProgress> progress;
        progress->SendRatio = false;
        progress->SendProgress = false;
        if (decoder->Code(input, output, &packed, &unpacked, progress) != S_OK || output->GetPos() != unpackedSize) return false;
    }
    const UInt32 crc = CrcCalc(decoded, unpackedSize);
    if ((info.modern ? crc : crc & 0xffff) != info.crc) return false;
    if (info.utf16 && (unpackedSize & 1)) return false;
    AString encoded;
    if (!info.utf16) {
        encoded.SetFrom_CalcLen((const char *)(const Byte *)decoded, unpackedSize);
        if (CheckUTF8_AString(encoded) && ConvertUTF8ToUnicode(encoded, text)) return true;
    }
    // 旧注释没有编码标记，有效 UTF-8 优先，其余使用传统 OEM CP437。
    CByteBuffer utf8((size_t)unpackedSize * 4 + 4);
    char *source = (char *)(Byte *)decoded;
    char *destination = (char *)(Byte *)utf8;
    size_t sourceLeft = unpackedSize;
    size_t destinationLeft = utf8.Size();
    iconv_t converter = iconv_open("UTF-8", info.utf16 ? "UTF-16LE" : "CP437");
    if (converter == (iconv_t)-1) return false;
    const size_t converted = iconv(converter, &source, &sourceLeft, &destination, &destinationLeft);
    iconv_close(converter);
    if (converted == (size_t)-1 || sourceLeft != 0) return false;
    encoded.SetFrom_CalcLen((const char *)(const Byte *)utf8, (unsigned)(utf8.Size() - destinationLeft));
    return ConvertUTF8ToUnicode(encoded, text);
}
