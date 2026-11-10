#import <Foundation/Foundation.h>
#include "zip_encoding.hpp"
#include <algorithm>
#include <array>
#include <dlfcn.h>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <utility>

static uint64_t littleEndian(const unsigned char* data, size_t size) {
    uint64_t value = 0;
    for (size_t index = 0; index < size; ++index) value |= uint64_t(data[index]) << (index * 8);
    return value;
}

// 只读取中央目录和至多 64 KiB 的旧编码文件名，避免为检测编码加载整个归档。
static std::string legacyZipNames(const char* archive) {
    std::ifstream input(archive, std::ios::binary | std::ios::ate);
    if (!input || input.tellg() < 22) return {};
    const uint64_t fileSize = static_cast<uint64_t>(input.tellg());
    const auto tailSize = static_cast<size_t>(std::min<uint64_t>(fileSize, 65557));
    std::vector<unsigned char> tail(tailSize);
    input.seekg(static_cast<std::streamoff>(fileSize - tailSize));
    input.read(reinterpret_cast<char*>(tail.data()), tail.size());
    size_t end = tail.size() - 22;
    while (littleEndian(tail.data() + end, 4) != 0x06054b50 ||
           end + 22 + littleEndian(tail.data() + end + 20, 2) != tail.size()) {
        if (end == 0) return {};
        --end;
    }
    const auto* record = tail.data() + end;
    if (littleEndian(record + 4, 2) != 0 || littleEndian(record + 6, 2) != 0) return {};
    uint64_t centralSize = littleEndian(record + 12, 4);
    uint64_t centralOffset = littleEndian(record + 16, 4);
    uint64_t centralEnd = fileSize - tailSize + end;
    if (centralSize == UINT32_MAX || centralOffset == UINT32_MAX) {
        if (end < 20 || littleEndian(record - 20, 4) != 0x07064b50) return {};
        const uint64_t zip64Offset = littleEndian(record - 12, 8);
        if (fileSize < 56 || zip64Offset > fileSize - 56) return {};
        std::array<unsigned char, 56> zip64{};
        input.seekg(static_cast<std::streamoff>(zip64Offset));
        input.read(reinterpret_cast<char*>(zip64.data()), zip64.size());
        if (!input || littleEndian(zip64.data(), 4) != 0x06064b50) return {};
        centralSize = littleEndian(zip64.data() + 40, 8);
        centralOffset = littleEndian(zip64.data() + 48, 8);
        centralEnd = zip64Offset;
    }
    if (centralSize > centralEnd || centralOffset > fileSize - centralSize) return {};
    // 部分自解压 ZIP 的中央目录偏移不包含可执行前缀。
    std::array<unsigned char, 46> header{};
    input.seekg(static_cast<std::streamoff>(centralOffset));
    input.read(reinterpret_cast<char*>(header.data()), header.size());
    if (!input || littleEndian(header.data(), 4) != 0x02014b50) {
        centralOffset = centralEnd - centralSize;
        input.clear();
    }
    uint64_t consumed = 0;
    std::string sample;
    while (centralSize - consumed >= header.size() && sample.size() < 65536) {
        input.seekg(static_cast<std::streamoff>(centralOffset + consumed));
        input.read(reinterpret_cast<char*>(header.data()), header.size());
        if (!input || littleEndian(header.data(), 4) != 0x02014b50) return {};
        const auto nameSize = littleEndian(header.data() + 28, 2);
        const auto recordSize = header.size() + nameSize + littleEndian(header.data() + 30, 2) + littleEndian(header.data() + 32, 2);
        if (recordSize > centralSize - consumed) return {};
        if ((littleEndian(header.data() + 8, 2) & 0x0800) == 0) {
            std::string name(nameSize, '\0');
            input.read(name.data(), name.size());
            if (!input) return {};
            if (std::any_of(name.begin(), name.end(), [](unsigned char value) { return value >= 128; })) {
                if (sample.size() + name.size() + 1 > 65536) break;
                sample += name + '\n';
            }
        }
        consumed += recordSize;
    }
    return sample;
}

uint32_t detectZipCodePage(const char* archive) {
    const auto sample = legacyZipNames(archive);
    if (sample.empty()) return 65001;
    @autoreleasepool {
        NSData* data = [NSData dataWithBytes:sample.data() length:sample.size()];
        if ([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]) return 65001;
        const std::array<std::pair<uint32_t, CFStringEncoding>, 6> encodings = {{
            {54936, kCFStringEncodingGB_18030_2000}, {932, kCFStringEncodingDOSJapanese},
            {950, kCFStringEncodingBig5}, {949, kCFStringEncodingDOSKorean},
            {1252, kCFStringEncodingWindowsLatin1}, {437, kCFStringEncodingDOSLatinUS}
        }};
        NSMutableArray* suggestions = [NSMutableArray array];
        for (const auto& [codePage, encoding] : encodings) {
            [suggestions addObject:@(CFStringConvertEncodingToNSStringEncoding(encoding))];
        }
        const auto detected = [NSString stringEncodingForData:data encodingOptions:@{
            NSStringEncodingDetectionSuggestedEncodingsKey:suggestions,
            NSStringEncodingDetectionUseOnlySuggestedEncodingsKey:@YES,
            NSStringEncodingDetectionAllowLossyKey:@NO
        } convertedString:nil usedLossyConversion:nil];
        for (const auto& [codePage, encoding] : encodings) {
            if (CFStringConvertEncodingToNSStringEncoding(encoding) == detected) return codePage;
        }
        return 437;
    }
}

ZipEncodingScope::ZipEncodingScope(const char* engine, const char* archive, uint32_t requested)
    : handle(nullptr), setCodePage(nullptr), previous(0),
      selected(requested == 0 ? detectZipCodePage(archive) : requested) {
    const std::array<uint32_t, 8> supported = {65001, 54936, 936, 932, 950, 949, 1252, 437};
    if (std::find(supported.begin(), supported.end(), selected) == supported.end()) {
        throw std::runtime_error("不支持的 ZIP 文件名编码");
    }
    handle = dlopen(engine, RTLD_LAZY | RTLD_LOCAL);
    if (handle) setCodePage = reinterpret_cast<SetCodePage>(dlsym(handle, "f7zip_set_codepage"));
    if (!setCodePage) {
        if (handle) dlclose(handle);
        throw std::runtime_error("原生引擎缺少文件名编码支持，请重新构建应用");
    }
    previous = setCodePage(selected);
}

ZipEncodingScope::~ZipEncodingScope() {
    setCodePage(previous);
    dlclose(handle);
}

void ZipEncodingScope::detectArchive(const char* archive) {
    selected = detectZipCodePage(archive);
    setCodePage(selected);
}

std::string normalizeUnicodeName(const std::string& value, uint32_t mode) {
    if (mode == 0) return value;
    if (mode > 2) throw std::runtime_error("无效的 Unicode 文件名规范化选项");
    if (std::all_of(value.begin(), value.end(), [](unsigned char byte) { return byte > 0 && byte < 128; })) return value;
    @autoreleasepool {
        if (value.find('\0') != std::string::npos) throw std::runtime_error("文件名包含空字符");
        NSString* source = [NSString stringWithUTF8String:value.c_str()];
        if (!source) throw std::runtime_error("文件名不是有效的 UTF-8，无法规范化");
        NSString* normalized = mode == 1 ? source.precomposedStringWithCanonicalMapping : source.decomposedStringWithCanonicalMapping;
        return std::string(normalized.UTF8String);
    }
}
