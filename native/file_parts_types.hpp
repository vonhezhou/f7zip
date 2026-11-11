#pragma once
#include <cstdint>
#include <string>
#include <vector>

struct FilePartInfo {
    std::string name;
    uint64_t size = 0;
    std::string sha256;
};

struct FilePartsInfo {
    std::string name;
    std::string prefix;
    uint64_t size = 0;
    uint64_t partSize = 0;
    std::string sha256;
    uint32_t permissions = 0;
    int64_t modified = 0;
    uint32_t modifiedNanoseconds = 0;
    std::vector<FilePartInfo> parts;
};

FilePartsInfo parseFilePartsManifest(const std::string& content);
