#pragma once
#include <filesystem>
#include <fstream>
#include <array>
#include <vector>
#include <map>
#include <set>
#include <mutex>
#include <sstream>
#include <iomanip>
#include <deque>
#include <regex>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>

#ifdef __APPLE__
#include <copyfile.h>
#include <sys/file.h>
#include <sys/xattr.h>
#include <CommonCrypto/CommonDigest.h>
inline std::filesystem::path descriptorPath(int descriptor, const std::filesystem::path& fallback) {
    char buffer[PATH_MAX];
    return fcntl(descriptor, F_GETPATH, buffer) == 0 ? std::filesystem::path(buffer) : fallback;
}
#else
#include "C/Sha256.h"
using CC_SHA256_CTX = CSha256;
using CC_LONG = size_t;
constexpr size_t CC_SHA256_DIGEST_LENGTH = SHA256_DIGEST_SIZE;
inline void CC_SHA256_Init(CSha256* context) {
    static std::once_flag prepared;
    std::call_once(prepared, Sha256Prepare);
    Sha256_Init(context);
}
inline void CC_SHA256_Update(CSha256* context, const void* bytes, size_t size) {
    Sha256_Update(context, static_cast<const Byte*>(bytes), size);
}
inline void CC_SHA256_Final(unsigned char* digest, CSha256* context) { Sha256_Final(context, digest); }

#ifdef _WIN32
#include "native_windows.hpp"
#else
#include <sys/file.h>
#include <sys/syscall.h>
#include <linux/fs.h>
#include <sys/xattr.h>
#define st_atimespec st_atim
#define st_mtimespec st_mtim
#define st_ctimespec st_ctim
constexpr unsigned RENAME_EXCL = RENAME_NOREPLACE;
constexpr unsigned RENAME_SWAP = RENAME_EXCHANGE;
inline int renamex_np(const char* source, const char* target, unsigned flags) {
    return static_cast<int>(syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, target, flags));
}
inline int renameatx_np(int sourceDirectory, const char* source, int targetDirectory, const char* target, unsigned flags) {
    return static_cast<int>(syscall(SYS_renameat2, sourceDirectory, source, targetDirectory, target, flags));
}
inline std::filesystem::path descriptorPath(int descriptor, const std::filesystem::path& fallback) {
    std::error_code error;
    auto path = std::filesystem::read_symlink("/proc/self/fd/" + std::to_string(descriptor), error);
    return error ? fallback : path;
}
#endif


constexpr unsigned COPYFILE_ALL = 1;
constexpr unsigned COPYFILE_EXCL = 2;
constexpr unsigned COPYFILE_NOFOLLOW = 4;
constexpr unsigned COPYFILE_METADATA = 8;
constexpr unsigned COPYFILE_XATTR = 16;
constexpr unsigned COPYFILE_PACK = 32;

// 仅 macOS 生成 AppleDouble。其他系统复制本机权限和时间，已有侧车文件作为普通条目保留。
inline int copyfile(const std::filesystem::path& source, const std::filesystem::path& target, void*, unsigned flags) {
    try {
        if (flags & COPYFILE_PACK) { errno = ENOTSUP; return -1; }
        if ((flags & COPYFILE_NOFOLLOW) && std::filesystem::is_symlink(std::filesystem::symlink_status(source))) {
            errno = ELOOP;
            return -1;
        }
        if (flags & COPYFILE_ALL) {
#ifdef _WIN32
            // 流式写入继承私有暂存目录 ACL，避免 CopyFile 将公开来源的 ACL 带入暂存区。
            const int input = f7win::openFile(source, O_RDONLY | O_NOFOLLOW);
            if (input < 0) return -1;
            const int output = f7win::openFile(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW);
            if (output < 0) { _close(input); return -1; }
            std::array<char, 65536> buffer;
            while (true) {
                const int read = _read(input, buffer.data(), static_cast<unsigned>(buffer.size()));
                if (read < 0) { _close(input); _close(output); return -1; }
                if (read == 0) break;
                size_t offset = 0;
                const auto size = static_cast<size_t>(read);
                while (offset < size) {
                    const int count = _write(output, buffer.data() + offset, static_cast<unsigned>(size - offset));
                    if (count <= 0) { _close(input); _close(output); return -1; }
                    offset += static_cast<size_t>(count);
                }
            }
            const int inputClosed = _close(input);
            const int outputClosed = _close(output);
            if (inputClosed != 0 || outputClosed != 0) { errno = EIO; return -1; }
#else
            std::filesystem::copy_file(source, target, flags & COPYFILE_EXCL
                ? std::filesystem::copy_options::none : std::filesystem::copy_options::overwrite_existing);
#endif
        }
        std::filesystem::permissions(target, std::filesystem::status(source).permissions());
        std::filesystem::last_write_time(target, std::filesystem::last_write_time(source));
#ifndef _WIN32
        auto size = listxattr(source.c_str(), nullptr, 0);
        if (size < 0 && errno != ENOTSUP) return -1;
        std::vector<char> names(size > 0 ? static_cast<size_t>(size) : 0);
        if (size > 0 && listxattr(source.c_str(), names.data(), names.size()) != size) return -1;
        for (size_t offset = 0; offset < names.size();) {
            const char* name = names.data() + offset;
            const auto length = getxattr(source.c_str(), name, nullptr, 0);
            if (length < 0) return -1;
            std::vector<char> value(static_cast<size_t>(length));
            if (getxattr(source.c_str(), name, value.data(), value.size()) != length ||
                setxattr(target.c_str(), name, value.data(), value.size(), 0) != 0) return -1;
            offset += std::strlen(name) + 1;
        }
#endif
        return 0;
    } catch (const std::filesystem::filesystem_error& error) {
        errno = error.code().value();
        return -1;
    }
}
#endif

inline int replaceArchive(const std::filesystem::path& source, const std::filesystem::path& target) {
#ifdef _WIN32
    return ReplaceFileW(target.c_str(), source.c_str(), nullptr, REPLACEFILE_IGNORE_MERGE_ERRORS, nullptr, nullptr) ? 0 : f7win::failure();
#else
    return rename(source.c_str(), target.c_str());
#endif
}

inline int openPrivateDirectory(const std::filesystem::path& path) {
#ifdef _WIN32
    return f7win::openFile(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | f7win::movableDirectory);
#else
    return open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
#endif
}

inline int openArchiveLock(const std::filesystem::path& path) {
#ifdef _WIN32
    const DWORD attributes = GetFileAttributesW(path.c_str());
    const int flags = attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY)
        ? O_DIRECTORY : 0;
    return f7win::openFile(path, O_RDONLY | O_NOFOLLOW | flags);
#else
    return open(path.c_str(), O_RDONLY | O_NOFOLLOW);
#endif
}

inline void removePrivateTree(const std::filesystem::path& path, std::error_code& error) {
#ifdef _WIN32
    for (std::filesystem::recursive_directory_iterator iterator(path, error), end; !error && iterator != end; iterator.increment(error)) {
        const auto attributes = GetFileAttributesW(iterator->path().c_str());
        if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_READONLY) &&
            !(attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
            SetFileAttributesW(iterator->path().c_str(), attributes & ~FILE_ATTRIBUTE_READONLY);
        }
    }
    if (error) return;
#endif
    std::filesystem::remove_all(path, error);
}
