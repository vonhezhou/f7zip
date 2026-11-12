#include "file_parts_types.hpp"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <iomanip>
#include <sstream>
#include <stdexcept>

using Json = nlohmann::json;
static std::string manifestString(const Json& value) {
    if (!value.is_string()) throw std::runtime_error("分片清单缺少有效文本字段");
    return value.get<std::string>();
}
static int64_t manifestInteger(const Json& value) {
    if (!value.is_number_integer() || (value.is_number_unsigned() && value.get<uint64_t>() > INT64_MAX)) {
        throw std::runtime_error("分片清单数字字段必须为受支持的整数");
    }
    return value.get<int64_t>();
}
static uint64_t manifestSize(const Json& value, uint64_t maximum) {
    const auto number = manifestInteger(value);
    if (number < 0 || static_cast<uint64_t>(number) > maximum) throw std::runtime_error("分片清单数字超出支持范围");
    return static_cast<uint64_t>(number);
}
static std::string manifestDigest(const Json& value) {
    auto digest = manifestString(value);
    if (digest.size() != 64 || !std::all_of(digest.begin(), digest.end(), [](unsigned char byte) { return std::isxdigit(byte); })) {
        throw std::runtime_error("分片清单包含无效 SHA-256");
    }
    std::transform(digest.begin(), digest.end(), digest.begin(), [](unsigned char byte) { return std::tolower(byte); });
    return digest;
}
static std::string manifestName(const Json& value) {
    auto name = manifestString(value);
    if (name.empty() || name == "." || name == ".." || name.find('/') != std::string::npos || name.find('\0') != std::string::npos) {
        throw std::runtime_error("分片清单文件名不能越过所在目录");
    }
#ifdef _WIN32
    if (name.find_first_of("\\:") != std::string::npos) throw std::runtime_error("分片清单包含 Windows 不支持的文件名");
#endif
    return name;
}
FilePartsInfo parseFilePartsManifest(const std::string& content) {
    if (content.size() > 4 * 1024 * 1024) throw std::runtime_error("分片清单超过 4 MiB");
    const auto value = Json::parse(content);
    if (!value.is_object() || value.at("format") != "F7ZipFileParts" || manifestInteger(value.at("version")) != 1) {
        throw std::runtime_error("不支持的分片清单版本");
    }
    FilePartsInfo info;
    info.name = manifestName(value.at("name"));
    info.prefix = manifestName(value.at("prefix"));
    info.size = manifestSize(value.at("size"), INT64_MAX);
    info.partSize = manifestSize(value.at("partSize"), 2097151ULL * 1048576);
    if (!info.partSize) throw std::runtime_error("分片大小必须大于零");
    info.sha256 = manifestDigest(value.at("sha256"));
    info.permissions = static_cast<uint32_t>(manifestSize(value.at("permissions"), 0777));
    info.modified = manifestInteger(value.at("modified"));
    info.modifiedNanoseconds = static_cast<uint32_t>(manifestSize(value.at("modifiedNanoseconds"), 999999999));
    const auto& parts = value.at("parts");
    const uint64_t count = std::max<uint64_t>(1, info.size / info.partSize + (info.size % info.partSize != 0));
    if (!parts.is_array() || parts.size() != count || count > 10000) throw std::runtime_error("分片数量与原文件大小不一致或超过 10000 片");
    uint64_t remaining = info.size;
    for (size_t index = 0; index < parts.size(); ++index) {
        const auto& part = parts[index];
        if (!part.is_object()) throw std::runtime_error("分片清单条目无效");
        std::ostringstream expected;
        expected << info.prefix << '.' << std::setw(3) << std::setfill('0') << index + 1;
        FilePartInfo entry;
        entry.name = manifestName(part.at("name"));
        entry.size = manifestSize(part.at("size"), info.partSize);
        entry.sha256 = manifestDigest(part.at("sha256"));
        if (entry.name != expected.str() || entry.size != std::min(info.partSize, remaining)) throw std::runtime_error("分片顺序、名称或大小与清单不一致");
        remaining -= entry.size;
        info.parts.push_back(std::move(entry));
    }
    return info;
}
