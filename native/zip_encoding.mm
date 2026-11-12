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
#include <unistd.h>

#include "zip_encoding_common.hpp"

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

ZipEncodingScope::ZipEncodingScope(const char* engine, const std::filesystem::path& archive, uint32_t requested)
    : handle(nullptr), setCodePage(nullptr), previous(0),
      selected(requested == 0 ? detectZipCodePage(archive.u8string().c_str()) : requested) {
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

void ZipEncodingScope::detectArchive(const std::filesystem::path& archive) {
    selected = detectZipCodePage(archive.u8string().c_str());
    setCodePage(selected);
}

std::string windowsFilenameKey(const std::string& value) {
    @autoreleasepool {
        NSString* text = [NSString stringWithUTF8String:value.c_str()];
        if (!text) throw std::runtime_error("Windows 文件名不是有效的 UTF-8");
        return std::string(text.precomposedStringWithCanonicalMapping.uppercaseString.UTF8String);
    }
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

std::string moveArchiveToTrash(const std::string& path) {
    @autoreleasepool {
        NSURL* source = [NSURL fileURLWithFileSystemRepresentation:path.c_str() isDirectory:NO relativeToURL:nil];
        NSURL* trashed = nil;
        NSError* error = nil;
        if (![[NSFileManager defaultManager] trashItemAtURL:source resultingItemURL:&trashed error:&error]) {
            throw std::runtime_error(std::string("无法移至废纸篓。") + (error.localizedDescription.UTF8String ?: "系统回收失败"));
        }
        return trashed ? std::string(trashed.fileSystemRepresentation) : std::string();
    }
}
