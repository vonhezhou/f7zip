#import <Foundation/Foundation.h>
#include "file_parts_types.hpp"
#include <algorithm>
#include <iomanip>
#include <sstream>
#include <stdexcept>

static std::string manifestString(id value) {
    if (![value isKindOfClass:[NSString class]]) throw std::runtime_error("分片清单缺少有效文本字段");
    return std::string([value UTF8String], [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
}

static int64_t manifestInteger(id value) {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((CFTypeRef)value) == CFBooleanGetTypeID() ||
        CFNumberIsFloatType((CFNumberRef)value)) throw std::runtime_error("分片清单数字字段必须为整数");
    return [value longLongValue];
}

static uint64_t manifestSize(id value, uint64_t maximum) {
    const auto number = manifestInteger(value);
    if (number < 0 || static_cast<uint64_t>(number) > maximum) throw std::runtime_error("分片清单数字超出支持范围");
    return static_cast<uint64_t>(number);
}

static std::string manifestDigest(id value) {
    auto digest = manifestString(value);
    if (digest.size() != 64 || !std::all_of(digest.begin(), digest.end(), [](unsigned char byte) { return std::isxdigit(byte); })) {
        throw std::runtime_error("分片清单包含无效 SHA-256");
    }
    std::transform(digest.begin(), digest.end(), digest.begin(), [](unsigned char byte) { return std::tolower(byte); });
    return digest;
}

static std::string manifestName(id value) {
    auto name = manifestString(value);
    if (name.empty() || name == "." || name == ".." || name.find('/') != std::string::npos || name.find('\0') != std::string::npos) {
        throw std::runtime_error("分片清单文件名不能越过所在目录");
    }
    return name;
}

FilePartsInfo parseFilePartsManifest(const std::string& content) {
    if (content.size() > 4 * 1024 * 1024) throw std::runtime_error("分片清单超过 4 MiB");
    @autoreleasepool {
        NSData* data = [NSData dataWithBytes:content.data() length:content.size()];
        id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr];
        if (![object isKindOfClass:[NSDictionary class]]) throw std::runtime_error("无法读取 F7Zip 分片清单");
        NSDictionary* value = object;
        if (![value[@"format"] isEqual:@"F7ZipFileParts"] || manifestInteger(value[@"version"]) != 1) {
            throw std::runtime_error("不支持的分片清单版本");
        }
        FilePartsInfo info;
        info.name = manifestName(value[@"name"]);
        info.prefix = manifestName(value[@"prefix"]);
        info.size = manifestSize(value[@"size"], INT64_MAX);
        info.partSize = manifestSize(value[@"partSize"], 2097151ULL * 1048576);
        if (!info.partSize) throw std::runtime_error("分片大小必须大于零");
        info.sha256 = manifestDigest(value[@"sha256"]);
        info.permissions = static_cast<uint32_t>(manifestSize(value[@"permissions"], 0777));
        info.modified = manifestInteger(value[@"modified"]);
        info.modifiedNanoseconds = static_cast<uint32_t>(manifestSize(value[@"modifiedNanoseconds"], 999999999));
        id parts = value[@"parts"];
        const uint64_t count = std::max<uint64_t>(1, info.size / info.partSize + (info.size % info.partSize != 0));
        if (![parts isKindOfClass:[NSArray class]] || [parts count] != count || count > 10000) {
            throw std::runtime_error("分片数量与原文件大小不一致或超过 10000 片");
        }
        uint64_t remaining = info.size;
        for (NSUInteger index = 0; index < [parts count]; ++index) {
            id part = parts[index];
            if (![part isKindOfClass:[NSDictionary class]]) throw std::runtime_error("分片清单条目无效");
            std::ostringstream expected;
            expected << info.prefix << '.' << std::setw(3) << std::setfill('0') << index + 1;
            FilePartInfo entry;
            entry.name = manifestName(part[@"name"]);
            entry.size = manifestSize(part[@"size"], info.partSize);
            entry.sha256 = manifestDigest(part[@"sha256"]);
            if (entry.name != expected.str() || entry.size != std::min(info.partSize, remaining)) {
                throw std::runtime_error("分片顺序、名称或大小与清单不一致");
            }
            remaining -= entry.size;
            info.parts.push_back(std::move(entry));
        }
        return info;
    }
}
