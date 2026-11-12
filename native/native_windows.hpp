#pragma once
#include <windows.h>
#include <sddl.h>
#include <io.h>
#include <random>
#include <memory>

// 目标目录句柄禁止删除共享，私有暂存目录允许随发布移动。所有名称均以 UTF-8 进入。
namespace f7win {
namespace fs = std::filesystem;
// ReplaceFile 发生部分失败时，调用方必须保留暂存目录中的原文件。
inline thread_local bool needsStagingRecovery = false;
struct FileStatus {
    uint64_t st_dev = 0, st_ino = 0, st_size = 0, st_nlink = 0;
    unsigned st_mode = 0;
    timespec st_atimespec{}, st_mtimespec{}, st_ctimespec{};
};
inline int failure() {
    switch (GetLastError()) {
        case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: errno = ENOENT; break;
        case ERROR_FILE_EXISTS: case ERROR_ALREADY_EXISTS: errno = EEXIST; break;
        case ERROR_ACCESS_DENIED: errno = EACCES; break;
        case ERROR_SHARING_VIOLATION: case ERROR_LOCK_VIOLATION: errno = EBUSY; break;
        case ERROR_DISK_FULL: case ERROR_HANDLE_DISK_FULL: errno = ENOSPC; break;
        case ERROR_NOT_SAME_DEVICE: errno = EXDEV; break;
        default: errno = EIO; break;
    }
    return -1;
}
inline HANDLE handle(int descriptor) { return reinterpret_cast<HANDLE>(_get_osfhandle(descriptor)); }
inline timespec timestamp(FILETIME value) {
    const uint64_t ticks = (uint64_t(value.dwHighDateTime) << 32) | value.dwLowDateTime;
    return {static_cast<int64_t>(ticks / 10000000) - 11644473600LL, static_cast<long>((ticks % 10000000) * 100)};
}
inline int status(HANDLE file, FileStatus* result) {
    BY_HANDLE_FILE_INFORMATION info{};
    FILE_BASIC_INFO basic{};
    if (!GetFileInformationByHandle(file, &info) || !GetFileInformationByHandleEx(file, FileBasicInfo, &basic, sizeof(basic))) return failure();
    result->st_dev = info.dwVolumeSerialNumber;
    result->st_ino = (uint64_t(info.nFileIndexHigh) << 32) | info.nFileIndexLow;
    result->st_size = (uint64_t(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
    result->st_nlink = info.nNumberOfLinks;
    result->st_mode = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ? _S_IFDIR : _S_IFREG) |
        (info.dwFileAttributes & FILE_ATTRIBUTE_READONLY ? 0444 : 0666);
    if (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) result->st_mode = 0120000 | 0777;
    result->st_atimespec = timestamp(info.ftLastAccessTime);
    result->st_mtimespec = timestamp(info.ftLastWriteTime);
    ULARGE_INTEGER change{};
    change.QuadPart = basic.ChangeTime.QuadPart;
    result->st_ctimespec = timestamp({change.LowPart, change.HighPart});
    return 0;
}
inline int fileStatus(int descriptor, FileStatus* result) { return status(handle(descriptor), result); }
inline int pathStatus(const fs::path& path, FileStatus* result, bool follow) {
    HANDLE file = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | (follow ? 0 : FILE_FLAG_OPEN_REPARSE_POINT), nullptr);
    if (file == INVALID_HANDLE_VALUE) return failure();
    const int value = status(file, result);
    CloseHandle(file);
    return value;
}
constexpr int noFollow = 0x10000000, directory = 0x20000000, movableDirectory = 0x40000000;
inline int openFile(const fs::path& path, int flags, int = 0600) {
    const bool isDirectory = flags & directory;
    const DWORD access = FILE_READ_ATTRIBUTES | (isDirectory ? 0 : ((flags & O_WRONLY) ? GENERIC_WRITE : GENERIC_READ));
    const DWORD shareDelete = isDirectory && !(flags & movableDirectory) ? 0 : FILE_SHARE_DELETE;
    HANDLE file = CreateFileW(path.c_str(), access, FILE_SHARE_READ | FILE_SHARE_WRITE | shareDelete,
        nullptr, flags & O_CREAT ? CREATE_NEW : OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | (flags & noFollow ? FILE_FLAG_OPEN_REPARSE_POINT : 0), nullptr);
    if (file == INVALID_HANDLE_VALUE) return failure();
    FileStatus info;
    if (status(file, &info) != 0 || ((flags & noFollow) && (info.st_mode & 0170000) == 0120000) ||
        (isDirectory && (info.st_mode & 0170000) != _S_IFDIR)) {
        CloseHandle(file);
        errno = ELOOP;
        return -1;
    }
    const int descriptor = _open_osfhandle(reinterpret_cast<intptr_t>(file), (flags & O_WRONLY ? _O_WRONLY : _O_RDONLY) | _O_BINARY);
    if (descriptor < 0) CloseHandle(file);
    return descriptor;
}
inline fs::path descriptorPath(int descriptor, const fs::path& fallback = {}) {
    std::vector<wchar_t> buffer(32768);
    const DWORD size = GetFinalPathNameByHandleW(handle(descriptor), buffer.data(), static_cast<DWORD>(buffer.size()), FILE_NAME_NORMALIZED);
    if (!size || size >= buffer.size()) return fallback;
    std::wstring path(buffer.data(), size);
    // 目录迭代器返回普通 DOS/UNC 路径，统一前缀以保持相对路径计算一致。
    if (path.compare(0, 8, L"\\\\?\\UNC\\") == 0) path = L"\\\\" + path.substr(8);
    else if (path.size() > 5 && path.compare(0, 4, L"\\\\?\\") == 0 && path[5] == L':') path.erase(0, 4);
    return fs::path(path);
}
inline fs::path relativePath(int descriptor, const fs::path& name) {
    return descriptor == -100 ? name : descriptorPath(descriptor) / name;
}
inline int openAt(int descriptor, const fs::path& name, int flags, int mode = 0600) {
    return openFile(relativePath(descriptor, name), flags, mode);
}
inline int statusAt(int descriptor, const fs::path& name, FileStatus* result, int) {
    return pathStatus(relativePath(descriptor, name), result, false);
}
inline std::mutex lockGuard;
inline std::map<int, HANDLE> directoryLocks;
inline int lock(int descriptor, int operation) {
    std::lock_guard<std::mutex> guard(lockGuard);
    auto existing = directoryLocks.find(descriptor);
    if (operation == 8) {
        if (existing != directoryLocks.end()) {
            ReleaseMutex(existing->second);
            CloseHandle(existing->second);
            directoryLocks.erase(existing);
        }
        return 0;
    }
    if (existing != directoryLocks.end()) return 0;
    FileStatus info;
    if (fileStatus(descriptor, &info) != 0) return -1;
    const auto name = L"Local\\F7Zip-" + std::to_wstring(info.st_dev) + L"-" + std::to_wstring(info.st_ino);
    HANDLE mutex = CreateMutexW(nullptr, FALSE, name.c_str());
    if (!mutex) return failure();
    const DWORD state = WaitForSingleObject(mutex, 0);
    if (state != WAIT_OBJECT_0 && state != WAIT_ABANDONED) {
        CloseHandle(mutex);
        errno = EWOULDBLOCK;
        return -1;
    }
    directoryLocks.emplace(descriptor, mutex);
    return 0;
}
inline int closeFile(int descriptor) { lock(descriptor, 8); return _close(descriptor); }
inline int chmodFile(const fs::path& path, unsigned mode) {
    auto attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) return failure();
    if (attributes & FILE_ATTRIBUTE_DIRECTORY) return 0;
    attributes = mode & 0222 ? attributes & ~FILE_ATTRIBUTE_READONLY : attributes | FILE_ATTRIBUTE_READONLY;
    return SetFileAttributesW(path.c_str(), attributes) ? 0 : failure();
}
inline int chmodDescriptor(int descriptor, unsigned mode) { return chmodFile(descriptorPath(descriptor), mode); }
inline int setTimes(int descriptor, const timespec* times) {
    FILETIME values[2]{};
    FILETIME* selected[2]{};
    for (size_t index = 0; index < 2; ++index) {
        if (times[index].tv_nsec == 1073741822) continue;
        uint64_t ticks;
        if (times[index].tv_nsec == 1073741823) {
            GetSystemTimeAsFileTime(&values[index]);
        } else {
            constexpr int64_t epoch = 11644473600LL;
            if (times[index].tv_nsec < 0 || times[index].tv_nsec >= 1000000000 ||
                times[index].tv_sec < -epoch || times[index].tv_sec > static_cast<int64_t>(UINT64_MAX / 10000000) - epoch) {
                errno = EINVAL;
                return -1;
            }
            const auto seconds = static_cast<uint64_t>(times[index].tv_sec + epoch);
            const auto fraction = static_cast<uint64_t>(times[index].tv_nsec / 100);
            if (seconds > (UINT64_MAX - fraction) / 10000000) { errno = EINVAL; return -1; }
            ticks = seconds * 10000000 + fraction;
            values[index] = {static_cast<DWORD>(ticks), static_cast<DWORD>(ticks >> 32)};
        }
        selected[index] = &values[index];
    }
    return SetFileTime(handle(descriptor), nullptr, selected[0], selected[1]) ? 0 : failure();
}
inline int setPathTimes(int directoryDescriptor, const fs::path& path, const timespec* times, int flags) {
    HANDLE file = CreateFileW(relativePath(directoryDescriptor, path).c_str(), FILE_WRITE_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | (flags ? FILE_FLAG_OPEN_REPARSE_POINT : 0), nullptr);
    if (file == INVALID_HANDLE_VALUE) return failure();
    const int descriptor = _open_osfhandle(reinterpret_cast<intptr_t>(file), _O_RDONLY | _O_BINARY);
    if (descriptor < 0) { CloseHandle(file); return -1; }
    const int result = setTimes(descriptor, times);
    _close(descriptor);
    return result;
}
inline int renameExclusive(const fs::path& source, const fs::path& target, unsigned flags) {
    if (flags == 2) {
        // ReplaceFile 原子替换普通文件，同时在原暂存路径保留旧文件供回滚。
        const auto spare = source.parent_path() / (L".swap-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
        if (!ReplaceFileW(target.c_str(), source.c_str(), spare.c_str(), 0, nullptr, nullptr)) {
            const DWORD error = GetLastError();
            if (GetFileAttributesW(spare.c_str()) != INVALID_FILE_ATTRIBUTES &&
                !MoveFileExW(spare.c_str(), target.c_str(), MOVEFILE_WRITE_THROUGH)) needsStagingRecovery = true;
            SetLastError(error);
            return failure();
        }
        if (!MoveFileExW(spare.c_str(), source.c_str(), MOVEFILE_WRITE_THROUGH)) {
            needsStagingRecovery = true;
            return failure();
        }
        return 0;
    }
    return MoveFileExW(source.c_str(), target.c_str(), MOVEFILE_WRITE_THROUGH) ? 0 : failure();
}
inline int renameAt(int sourceDirectory, const fs::path& source, int targetDirectory, const fs::path& target, unsigned flags) {
    return renameExclusive(relativePath(sourceDirectory, source), relativePath(targetDirectory, target), flags);
}
inline char* temporaryDirectory(char* pattern) {
    const size_t size = std::strlen(pattern);
    std::random_device random;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;OICI;FA;;;OW)(A;OICI;FA;;;SY)",
        SDDL_REVISION_1, &descriptor, nullptr)) { failure(); return nullptr; }
    std::unique_ptr<void, decltype(&LocalFree)> security(descriptor, LocalFree);
    SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
    constexpr char alphabet[] = "0123456789abcdefghijklmnopqrstuvwxyz";
    for (int attempt = 0; attempt < 100; ++attempt) {
        for (size_t index = size - 6; index < size; ++index) pattern[index] = alphabet[random() % 36];
        if (CreateDirectoryW(fs::u8path(pattern).c_str(), &attributes)) return pattern;
        if (GetLastError() != ERROR_ALREADY_EXISTS) { failure(); return nullptr; }
    }
    errno = EEXIST;
    return nullptr;
}
inline int hardLink(const fs::path& source, const fs::path& target) {
    return CreateHardLinkW(target.c_str(), source.c_str(), nullptr) ? 0 : failure();
}
inline int symbolicLink(const fs::path& source, const fs::path& target) {
    const DWORD attributes = GetFileAttributesW((target.parent_path() / source).c_str());
    const DWORD flags = 2 | (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) ? SYMBOLIC_LINK_FLAG_DIRECTORY : 0);
    return CreateSymbolicLinkW(target.c_str(), source.c_str(), flags) ? 0 : failure();
}
inline int removeFile(const fs::path& path) {
    return DeleteFileW(path.c_str()) ? 0 : failure();
}
inline int removeAt(int descriptor, const fs::path& name, int) { return removeFile(relativePath(descriptor, name)); }
inline int syncFile(int descriptor) {
    FileStatus info;
    if (fileStatus(descriptor, &info) != 0) return -1;
    if ((info.st_mode & 0170000) == _S_IFDIR) return 0;
    if (FlushFileBuffers(handle(descriptor))) return 0;
    HANDLE writable = ReOpenFile(handle(descriptor), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0);
    if (writable == INVALID_HANDLE_VALUE) return failure();
    const bool flushed = FlushFileBuffers(writable);
    const DWORD error = GetLastError();
    CloseHandle(writable);
    if (!flushed) { SetLastError(error); return failure(); }
    return 0;
}
}

using f7win::descriptorPath;
struct F7Stat : f7win::FileStatus {};
inline int F7Stat(const std::filesystem::path& path, struct F7Stat* info) { return f7win::pathStatus(path, info, true); }
inline int f7Lstat(const std::filesystem::path& path, struct F7Stat* info) { return f7win::pathStatus(path, info, false); }
inline ssize_t f7Pread(int descriptor, void* buffer, size_t size, int64_t offset) {
    LARGE_INTEGER position{};
    position.QuadPart = offset;
    if (!SetFilePointerEx(f7win::handle(descriptor), position, nullptr, FILE_BEGIN)) return f7win::failure();
    return _read(descriptor, buffer, static_cast<unsigned>(size));
}
#define stat F7Stat
#define lstat f7Lstat
#define fstat f7win::fileStatus
#define fstatat f7win::statusAt
#define open f7win::openFile
#define openat f7win::openAt
#define chmod f7win::chmodFile
#define fchmod f7win::chmodDescriptor
#define flock f7win::lock
#define utimensat f7win::setPathTimes
#define futimens f7win::setTimes
#define fsync f7win::syncFile
#define pread f7Pread
#define mkdtemp f7win::temporaryDirectory
#define renamex_np f7win::renameExclusive
#define renameatx_np f7win::renameAt
#define link(source, target) f7win::hardLink(source, target)
#define symlink(source, target) f7win::symbolicLink(source, target)
#define unlink f7win::removeFile
#define unlinkat f7win::removeAt
#define O_NOFOLLOW f7win::noFollow
#define O_DIRECTORY f7win::directory
#define O_NONBLOCK 0
#define AT_FDCWD -100
#define AT_SYMLINK_NOFOLLOW 1
#define UTIME_NOW 1073741823
#define UTIME_OMIT 1073741822
#define LOCK_EX 2
#define LOCK_NB 4
#define LOCK_UN 8
#define RENAME_EXCL 1
#define RENAME_SWAP 2
#ifndef S_ISREG
#define S_ISREG(mode) (((mode) & 0170000) == _S_IFREG)
#define S_ISDIR(mode) (((mode) & 0170000) == _S_IFDIR)
#endif
#define S_ISLNK(mode) (((mode) & 0170000) == 0120000)
#define access(filename, mode) _waccess(std::filesystem::path(filename).c_str(), mode)
#ifndef S_IFLNK
#define S_IFLNK 0120000
#endif
