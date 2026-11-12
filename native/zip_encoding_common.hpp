#pragma once
#include <filesystem>
static uint64_t littleEndian(const unsigned char* data, size_t size) {
    uint64_t value = 0;
    for (size_t index = 0; index < size; ++index) value |= uint64_t(data[index]) << (index * 8);
    return value;
}

// 只读取中央目录和至多 64 KiB 的旧编码文件名，避免为检测编码加载整个归档。
static std::string legacyZipNames(const char* archive) {
    std::ifstream input(std::filesystem::u8path(archive), std::ios::binary | std::ios::ate);
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

// EOCD 位于文件尾，修改归档注释不改变中央目录、ZIP64 或压缩数据偏移。
void replaceZipArchiveComment(const std::string& path, const std::string& comment) {
    if (comment.size() > 16384) throw std::runtime_error("注释最多支持 16384 个 UTF-8 字节");
    std::fstream file(std::filesystem::u8path(path), std::ios::binary | std::ios::in | std::ios::out | std::ios::ate);
    if (!file || file.tellg() < 22) throw std::runtime_error("无法读取 ZIP 结束记录");
    const auto size = static_cast<uint64_t>(file.tellg());
    const auto tailSize = static_cast<size_t>(std::min<uint64_t>(size, 65557));
    std::vector<unsigned char> tail(tailSize);
    file.seekg(static_cast<std::streamoff>(size - tailSize));
    file.read(reinterpret_cast<char*>(tail.data()), tail.size());
    size_t end = tail.size() - 22;
    while (littleEndian(tail.data() + end, 4) != 0x06054b50 ||
        end + 22 + littleEndian(tail.data() + end + 20, 2) != tail.size()) {
        if (end == 0) throw std::runtime_error("ZIP 结束记录不完整，已停止编辑注释");
        --end;
    }
    const auto offset = size - tailSize + end;
    const unsigned char length[2] = {static_cast<unsigned char>(comment.size()), static_cast<unsigned char>(comment.size() >> 8)};
    file.seekp(static_cast<std::streamoff>(offset + 20));
    file.write(reinterpret_cast<const char*>(length), 2);
    file.write(comment.data(), static_cast<std::streamsize>(comment.size()));
    file.close();
    if (!file) {
        throw std::runtime_error("无法完整保存 ZIP 归档注释");
    }
    std::filesystem::resize_file(std::filesystem::u8path(path), offset + 22 + comment.size());
}
