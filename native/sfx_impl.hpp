#pragma once
#include "password_text.hpp"

static bool hasSfxPrefix(const localfs::path& path) {
    std::ifstream input(path, std::ios::binary);
    char signature[2]{};
    input.read(signature, sizeof(signature));
    return input.gcount() == 2 && signature[0] == 'M' && signature[1] == 'Z';
}

static void validateSfxInputs(const std::vector<std::pair<std::string, std::string>>& inputs) {
    std::map<std::string, std::string> names;
    for (const auto& [source, name] : inputs) {
        if (localfs::is_symlink(localfs::symlink_status(source))) throw std::runtime_error("Windows SFX 创建暂不携带符号链接，请选择普通文件或目录");
        validateWindowsArchivePath(name);
        for (auto path = localfs::path(name); !path.empty(); path = path.parent_path()) {
            const auto raw = path.generic_string();
            const auto [found, inserted] = names.emplace(windowsFilenameKey(raw), raw);
            if (!inserted && found->second != raw) throw std::runtime_error("来源文件名在 Windows 下可能冲突。" + name);
        }
    }
}

// 仅解析内层归档，所有后续操作继续使用原文件的版本与现有发布保护。
static std::unique_ptr<BitArchiveReader> openArchiveForReading(const Bit7zLibrary& library,
    const localfs::path& path, const char* password, Job* job, bool& sfx, PasswordTextScope& passwordText) {
    sfx = hasSfxPrefix(path);
    if (!sfx) return std::make_unique<BitArchiveReader>(library, path.string(), BitFormat::Auto, password);
    passwordText.useUtf16();
    std::ifstream input(path, std::ios::binary);
    std::string prefix(16 * 1024 * 1024, '\0');
    input.read(prefix.data(), static_cast<std::streamsize>(prefix.size()));
    prefix.resize(static_cast<size_t>(input.gcount()));
    const std::pair<std::string, const BitInFormat*> formats[] = {
        {std::string("7z\xbc\xaf\x27\x1c", 6), &BitFormat::SevenZip},
        {std::string("PK\x03\x04", 4), &BitFormat::Zip},
        {std::string("Rar!\x1a\x07\x01\x00", 8), &BitFormat::Rar5},
        {std::string("Rar!\x1a\x07\x00", 7), &BitFormat::Rar}
    };
    for (const auto& [signature, format] : formats) {
        checkCancellation(job);
        if (prefix.find(signature) == std::string::npos) continue;
        try {
            auto reader = std::make_unique<BitArchiveReader>(library, path.string(), *format, password);
            const auto offset = reader->archiveProperty(BitProperty::Offset);
            if (offset.isUInt64() && offset.getUInt64() > 16ULL * 1024 * 1024) {
                throw std::runtime_error("自解压包前缀超过 16 MiB");
            }
            checkCancellation(job);
            return reader;
        } catch (const BitException& error) {
            if (error.code() == BitFailureSource::WrongPassword) throw;
        }
    }
    throw std::runtime_error("无法识别或打开自解压包中的 7z / ZIP / RAR 数据。支持前缀不超过 16 MiB 的 Windows SFX");
}

static localfs::path createSfx(const localfs::path& payload, const StagingDirectory& staging,
    const char* engine, const Bit7zLibrary& library, const char* password, Job* job) {
    const auto engineDirectory = localfs::path(engine).parent_path();
    // macOS 包内的 PE 模块作为资源保存，开发与独立 CLI 布局沿用引擎同目录。
    const auto moduleDirectory = engineDirectory.filename() == "F7Zip" && engineDirectory.parent_path().filename() == "Frameworks"
        ? engineDirectory.parent_path().parent_path() / "Resources" / "F7Zip" : engineDirectory;
    const auto modulePath = moduleDirectory / "7z-x86.sfx";
    FilePartInput module(modulePath);
    if (module.status.st_size != 214016) throw std::runtime_error("Windows SFX 模块大小不正确，请重新安装应用");
    std::string bytes(static_cast<size_t>(module.status.st_size), '\0');
    size_t done = 0;
    while (done < bytes.size()) {
        const auto count = module.read(bytes.data() + done, bytes.size() - done);
        if (!count) throw std::runtime_error("SFX 模块读取不完整");
        done += count;
    }
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    CC_SHA256_Update(&hash, bytes.data(), static_cast<CC_LONG>(bytes.size()));
    if (finishSha256(hash) != "73af2700392aa92bc9342ae63844dfeed157d8d68bd356326a9bddb5e9e312d7") {
        throw std::runtime_error("Windows SFX 模块校验失败，请重新安装应用");
    }
    FilePartOutput output(staging, "archive.exe");
    output.write(bytes.data(), bytes.size());
    FilePartInput content(payload);
    std::vector<char> buffer(1048576);
    while (true) {
        checkCancellation(job);
        const auto count = content.read(buffer.data(), buffer.size());
        if (!count) break;
        output.write(buffer.data(), count);
    }
    output.finish();
    const auto result = staging.currentPath() / "archive.exe";
    BitArchiveReader verified(library, result.string(), BitFormat::SevenZip, password);
    callbacks(verified, job);
    verified.test();
    checkCancellation(job);
    return result;
}
