#pragma once
#include <cstdint>
#include <string>
#include <filesystem>

uint32_t detectZipCodePage(const char* archive);

// 每个调用线程单独设置编码，避免不同压缩包的并发操作互相影响。
class ZipEncodingScope {
public:
    ZipEncodingScope(const char* engine, const std::filesystem::path& archive, uint32_t requested);
    ~ZipEncodingScope();
    uint32_t codePage() const { return selected; }
    void detectArchive(const std::filesystem::path& archive);
    ZipEncodingScope(const ZipEncodingScope&) = delete;
    ZipEncodingScope& operator=(const ZipEncodingScope&) = delete;
private:
    void* handle;
    using SetCodePage = uint32_t (*)(uint32_t);
    SetCodePage setCodePage;
    uint32_t previous;
    uint32_t selected;
};

std::string normalizeUnicodeName(const std::string& value, uint32_t mode);
std::string windowsFilenameKey(const std::string& value);
std::string moveArchiveToTrash(const std::string& path);

void replaceZipArchiveComment(const std::string& path, const std::string& comment);
