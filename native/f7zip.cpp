#include "zip_encoding.hpp"
#include <bit7z/bit7zlibrary.hpp>
#include <bit7z/bitarchivereader.hpp>
#include <bit7z/bitfilecompressor.hpp>
#include <bit7z/bitoutputarchive.hpp>
#include <bit7z/bitarchiveeditor.hpp>
#include <bit7z/bitexception.hpp>
#include <bit7z/biterror.hpp>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <limits.h>
#include <copyfile.h>
#include <map>
#include <regex>
#include <set>
#include <iomanip>
#include <deque>
#include <fstream>
#include <sys/xattr.h>

namespace localfs = std::filesystem;
using namespace bit7z;

struct Job {
    uint32_t codePage = 0;
    uint64_t volumeSize = 0;
    uint32_t extractionPolicy = 0;
    std::string expectedDestinationVersion;
    std::string exportPath;
    std::string exportVersion;
    uint64_t outputLimit = 0;
    std::atomic<bool> limitExceeded{false};
    std::atomic<uint64_t> total{0};
    std::atomic<uint64_t> completed{0};
    std::atomic<bool> cancelled{false};
    std::mutex mutex;
    std::string currentFile;
};

static std::string quote(const std::string& value) {
    std::ostringstream out;
    out << '"';
    const char* hex = "0123456789abcdef";
    for (unsigned char c : value) {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c < 32) out << "\\u00" << hex[c >> 4] << hex[c & 15];
        else out << c;
    }
    out << '"';
    return out.str();
}

static char* result(const std::string& value) { return strdup(value.c_str()); }

static void checkCancellation(Job* job) {
    if (job->cancelled.load()) throw std::runtime_error("操作已取消");
}

static void checkOutputBudget(uint64_t size, uint64_t& total, Job* job) {
    if (!job->outputLimit) return;
    if (size > job->outputLimit - total) {
        job->limitExceeded = true;
        throw std::runtime_error("预览内容超过资源上限，请缩小选中范围或直接解压");
    }
    total += size;
}

static void callbacks(BitAbstractArchiveHandler& handler, Job* job) {
    handler.setTotalCallback([job](uint64_t total) {
        job->total = total;
        if (job->outputLimit && total > job->outputLimit) job->limitExceeded = true;
    });
    handler.setProgressCallback([job](uint64_t value) {
        job->completed = value;
        if (job->outputLimit && value > job->outputLimit) job->limitExceeded = true;
        return !job->cancelled.load() && !job->limitExceeded.load();
    });
    handler.setFileCallback([job](const std::string& name) {
        std::lock_guard<std::mutex> guard(job->mutex);
        job->currentFile = name;
    });
}

// 解压到新建的私有目录，全部成功后才发布结果，失败和取消均清理中间文件。
class StagingDirectory {
public:
    localfs::path path;
    bool preserve = false;
    int descriptor = -1;
    explicit StagingDirectory(const localfs::path& parent) {
        auto pattern = (parent / ".f7zip-XXXXXX").string();
        std::vector<char> buffer(pattern.begin(), pattern.end());
        buffer.push_back(0);
        char* created = mkdtemp(buffer.data());
        if (!created) throw std::runtime_error("无法创建临时目录，请检查目标目录权限与磁盘空间");
        path = created;
        descriptor = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (descriptor < 0) {
            localfs::remove(path);
            throw std::runtime_error("无法打开临时目录");
        }
    }
    localfs::path currentPath() const {
        char buffer[PATH_MAX];
        return fcntl(descriptor, F_GETPATH, buffer) == 0 ? localfs::path(buffer) : path;
    }
    ~StagingDirectory() {
        std::error_code ignored;
        if (!preserve) localfs::remove_all(currentPath(), ignored);
        close(descriptor);
    }
};

static void publish(const localfs::path& source, const localfs::path& target) {
    // RENAME_EXCL 保证并发任务也不会覆盖已存在的文件或目录。
    if (renamex_np(source.c_str(), target.c_str(), RENAME_EXCL) != 0) {
        throw std::runtime_error(std::string("无法保存结果，目标可能已存在或不可写。") + strerror(errno));
    }
}

// 先检查全部顶层条目，再逐个排他发布。发布失败时将本次结果移回暂存目录。
static void publishContents(const localfs::path& staging, const localfs::path& target, Job* job = nullptr) {
    std::vector<localfs::path> names;
    for (const auto& entry : localfs::directory_iterator(staging)) {
        const auto name = entry.path().filename();
        if (localfs::symlink_status(target / name).type() != localfs::file_type::not_found) {
            throw std::runtime_error("目标已存在同名项目，请选择其他文件夹。" + name.string());
        }
        names.push_back(name);
    }
    size_t published = 0;
    try {
        for (const auto& name : names) {
            if (job) checkCancellation(job);
            publish(staging / name, target / name);
            ++published;
        }
        if (job) checkCancellation(job);
    } catch (...) {
        bool restored = true;
        while (published > 0) {
            const auto& name = names[--published];
            if (renamex_np((target / name).c_str(), (staging / name).c_str(), RENAME_EXCL) != 0) {
                restored = false;
            }
        }
        if (!restored) throw std::runtime_error("保存失败，部分结果仍保留在目标目录，请检查后重试。");
        throw;
    }
}

static void validateMaterializedLink(const localfs::path& link, const localfs::path& root) {
    std::error_code error;
    const auto resolved = localfs::canonical(link, error);
    if (error) throw std::runtime_error("链接目标缺失或存在循环，请同时解压其目标文件");
    const auto relative = resolved.lexically_relative(localfs::canonical(root));
    if (relative.empty() || *relative.begin() == "..") throw std::runtime_error("链接目标超出解压目录");
}

static void validateMaterializedLinks(const localfs::path& root) {
    for (const auto& entry : localfs::recursive_directory_iterator(root)) {
        if (localfs::is_symlink(entry.symlink_status())) validateMaterializedLink(entry.path(), root);
    }
}

static localfs::path validateLinkTarget(const std::string& name, const std::map<std::string, std::string>& links);

static void normalizeExportLinks(const localfs::path& root) {
    std::map<std::string, std::string> links;
    for (const auto& entry : localfs::recursive_directory_iterator(root)) {
        if (localfs::is_symlink(entry.symlink_status())) links[entry.path().lexically_relative(root).generic_string()] = localfs::read_symlink(entry.path()).generic_string();
    }
    for (const auto& [name, target] : links) {
        try { validateLinkTarget(name, links); }
        catch (const std::runtime_error&) {
            validateMaterializedLink(root / name, root);
            const auto relative = localfs::canonical(root / name).lexically_relative(localfs::canonical((root / name).parent_path()));
            struct stat parentStatus{}, linkStatus{};
            if (lstat((root / name).parent_path().c_str(), &parentStatus) != 0 || lstat((root / name).c_str(), &linkStatus) != 0) throw std::runtime_error("无法读取链接时间");
            if (unlink((root / name).c_str()) != 0 || symlink(relative.c_str(), (root / name).c_str()) != 0) {
                throw std::runtime_error("无法调整拖出目录中的相对链接");
            }
            const struct timespec linkTimes[] = {linkStatus.st_atimespec, linkStatus.st_mtimespec};
            const struct timespec parentTimes[] = {parentStatus.st_atimespec, parentStatus.st_mtimespec};
            if (utimensat(AT_FDCWD, (root / name).c_str(), linkTimes, AT_SYMLINK_NOFOLLOW) != 0 ||
                utimensat(AT_FDCWD, (root / name).parent_path().c_str(), parentTimes, 0) != 0) throw std::runtime_error("无法恢复拖出链接的时间");
        }
    }
}

// 仅去掉一个独占的顶层目录，内部目录结构保持完整，空目录也可直接发布。
static localfs::path extractionRoot(const localfs::path& staging, bool removeRedundantRoot) {
    if (!removeRedundantRoot) return staging;
    auto entry = localfs::directory_iterator(staging);
    if (entry == localfs::directory_iterator()) return staging;
    const auto root = entry->path();
    if (!localfs::is_directory(localfs::symlink_status(root))) return staging;
    if (++entry != localfs::directory_iterator()) return staging;
    std::map<std::string, std::string> links;
    for (const auto& item : localfs::recursive_directory_iterator(root)) {
        if (localfs::is_symlink(item.symlink_status())) links[item.path().lexically_relative(root).generic_string()] = localfs::read_symlink(item.path()).generic_string();
    }
    try {
        for (const auto& [name, target] : links) validateLinkTarget(name, links);
    } catch (const std::runtime_error&) {
        // 去掉包裹目录会改变链接边界时，保留这一层。
        return staging;
    }
    return root;
}

static void validateEntry(const BitArchiveItemInfo& item, bool allowLinks = false) {
    auto name = item.path();
    std::replace(name.begin(), name.end(), '\\', '/');
    localfs::path path(name);
    if (name.empty() || path.is_absolute() || name.find('\0') != std::string::npos ||
        (name.size() > 1 && name[1] == ':')) {
        throw std::runtime_error("压缩包包含不安全的文件路径");
    }
    for (const auto& part : path) {
        if (part == "..") throw std::runtime_error("压缩包包含越界文件路径");
    }
    const auto posix = item.itemProperty(BitProperty::PosixAttrib);
    const mode_t mode = posix.isUInt32() ? posix.getUInt32() : item.attributes() >> 16U;
    const mode_t type = mode & S_IFMT;
    if (type != 0 && type != S_IFREG && type != S_IFDIR && type != S_IFLNK) {
        throw std::runtime_error("归档包含不支持的设备、管道或套接字条目");
    }
    if (!allowLinks && (item.isSymLink() || !item.itemProperty(BitProperty::HardLink).isEmpty())) {
        throw std::runtime_error("当前版本暂不解压符号链接或硬链接");
    }
}

static std::string archiveVersion(const char* path) {
    struct stat info{};
    if (stat(path, &info) != 0 || !S_ISREG(info.st_mode)) {
        throw std::runtime_error("无法读取压缩包文件状态");
    }
    return std::to_string(info.st_dev) + ":" + std::to_string(info.st_ino) + ":" +
        std::to_string(info.st_size) + ":" + std::to_string(info.st_mtimespec.tv_sec) + ":" +
        std::to_string(info.st_mtimespec.tv_nsec) + ":" + std::to_string(info.st_ctimespec.tv_sec) + ":" +
        std::to_string(info.st_ctimespec.tv_nsec);
}

// 对同组分卷记录全部文件的版本，解压发布前检测任一卷被替换、增删或修改。
static std::string volumeFamily(const std::string& name) {
    static const std::vector<std::regex> patterns = {
        std::regex(R"(^([\s\S]*)\.[0-9]{3,}$)", std::regex::icase),
        std::regex(R"(^([\s\S]*)\.(zip|z[0-9]{2,})$)", std::regex::icase),
        std::regex(R"(^([\s\S]*)\.part[0-9]+\.rar$)", std::regex::icase),
        std::regex(R"(^([\s\S]*)\.(rar|r[0-9]{2,})$)", std::regex::icase)
    };
    for (size_t index = 0; index < patterns.size(); ++index) {
        std::smatch match;
        if (std::regex_match(name, match, patterns[index])) {
            auto key = std::to_string(index) + ":" + match[1].str();
            std::transform(key.begin(), key.end(), key.begin(),
                [](unsigned char value) { return static_cast<char>(std::tolower(value)); });
            return key;
        }
    }
    return {};
}

static std::string volumeVersion(const char* archive) {
    const auto path = localfs::absolute(archive);
    const auto family = volumeFamily(path.filename().string());
    if (family.empty()) return archiveVersion(archive);
    std::map<std::string, std::string> versions;
    for (const auto& entry : localfs::directory_iterator(path.parent_path())) {
        if (entry.is_regular_file() && volumeFamily(entry.path().filename().string()) == family) {
            versions.emplace(entry.path().filename().string(), archiveVersion(entry.path().c_str()));
        }
    }
    std::string version;
    for (const auto& [name, value] : versions) version += name + "=" + value + "\n";
    return version;
}

static localfs::path unpackSingleArchive(BitArchiveReader& reader, Job* job,
    std::vector<std::unique_ptr<StagingDirectory>>& intermediates) {
    uint64_t total = 0;
    for (const auto& item : reader.items()) {
        validateEntry(item);
        checkOutputBudget(item.size(), total, job);
    }
    intermediates.push_back(std::make_unique<StagingDirectory>(localfs::temp_directory_path()));
    const auto& directory = intermediates.back()->path;
    reader.extractTo(directory.string());
    checkCancellation(job);
    auto contents = localfs::directory_iterator(directory);
    if (contents == localfs::directory_iterator()) throw std::runtime_error("归档缺少内层文件");
    const auto inner = contents->path();
    if (!localfs::is_regular_file(localfs::symlink_status(inner)) || ++contents != localfs::directory_iterator()) {
        throw std::runtime_error("归档需要包含唯一的内层文件");
    }
    total = 0;
    checkOutputBudget(localfs::file_size(inner), total, job);
    return inner;
}

static void validateVolumes(BitArchiveReader& reader) {
    if (!reader.isMultiVolume()) return;
    const auto error = reader.archiveProperty(BitProperty::Error);
    if (error.isString() && !error.getString().empty()) {
        throw std::runtime_error("分卷不完整，请补齐全部分卷。" + error.getString());
    }
    const auto flags = reader.archiveProperty(BitProperty::ErrorFlags);
    if (!flags.isEmpty() && flags.getUInt32() != 0) {
        throw std::runtime_error("分卷缺失、顺序错误或损坏，请核对全部分卷");
    }
}

static std::string archiveItems(BitArchiveReader& reader, Job* job) {
    std::ostringstream out;
    out << '[';
    bool first = true;
    for (const auto& item : reader.items()) {
        checkCancellation(job);
        if (!first) out << ',';
        first = false;
        const auto time = item.itemProperty(BitProperty::MTime);
        const auto modified = time.isFileTime()
            ? std::chrono::duration_cast<std::chrono::seconds>(time.getTimePoint().time_since_epoch()).count() : 0;
        const auto method = item.itemProperty(BitProperty::Method);
        std::ostringstream crc;
        if (!item.itemProperty(BitProperty::CRC).isEmpty()) crc << std::uppercase << std::hex << std::setw(8) << std::setfill('0') << item.crc();
        out << "{\"index\":" << item.index() << ",\"path\":" << quote(item.path())
            << ",\"size\":" << item.size() << ",\"packed\":" << item.packSize()
            << ",\"directory\":" << (item.isDir() ? "true" : "false")
            << ",\"encrypted\":" << (item.isEncrypted() ? "true" : "false")
            << ",\"modified\":" << modified << ",\"method\":" << quote(method.isString() ? method.getString() : "")
            << ",\"crc\":" << quote(crc.str()) << '}';
    }
    out << ']';
    return out.str();
}

static std::string archiveComment(BitArchiveReader& reader) {
    const auto comment = reader.archiveProperty(BitProperty::Comment);
    return comment.isString() ? comment.getString() : "";
}

class ArchiveLock {
public:
    int descriptor;
    explicit ArchiveLock(const char* path) : descriptor(open(path, O_RDONLY | O_NOFOLLOW)) {
        if (descriptor < 0) throw std::runtime_error("无法打开待写入的位置，请检查目录或压缩包权限");
        if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
            close(descriptor);
            throw std::runtime_error("其他任务正在写入此位置，请稍后重试");
        }
    }
    ~ArchiveLock() { flock(descriptor, LOCK_UN); close(descriptor); }
};

// 检查完整数字卷组，防止旧的尾卷混入新结果。
static void checkOutputGroup(const localfs::path& target) {
    if (localfs::symlink_status(target).type() != localfs::file_type::not_found) {
        throw std::runtime_error("目标文件已存在，请使用新文件名");
    }
    const auto family = volumeFamily(target.filename().string() + ".001");
    for (const auto& entry : localfs::directory_iterator(target.parent_path())) {
        if (volumeFamily(entry.path().filename().string()) == family) {
            throw std::runtime_error("同名分卷已存在，请使用新文件名");
        }
    }
}

static std::string logicalPath(std::string value, bool allowRoot = false) {
    std::replace(value.begin(), value.end(), '\\', '/');
    if (value.find('\0') != std::string::npos || localfs::path(value).is_absolute() ||
        (value.size() > 1 && value[1] == ':')) throw std::runtime_error("压缩包内路径无效");
    for (const auto& part : localfs::path(value)) {
        if (part == "..") throw std::runtime_error("压缩包内路径不能越过根目录");
    }
    value = localfs::path(value).lexically_normal().generic_string();
    while (value.size() >= 2 && value.substr(0, 2) == "./") value.erase(0, 2);
    while (!value.empty() && value.back() == '/') value.pop_back();
    if (value == ".") value.clear();
    if (value.empty() && !allowRoot) throw std::runtime_error("压缩包内路径不能为空");
    return value;
}

static bool selectedPath(std::string path, const std::set<std::string>& selected) {
    while (!path.empty()) {
        if (selected.count(path)) return true;
        const auto slash = path.find_last_of('/');
        if (slash == std::string::npos) break;
        path.erase(slash);
    }
    return false;
}

static std::string appleDoubleTarget(const std::string& name) {
    const localfs::path path(name);
    const auto leaf = path.filename().string();
    if (leaf.rfind("._", 0) != 0 || leaf.size() <= 2) return {};
    auto parent = path.parent_path().generic_string();
    if (parent == "__MACOSX") parent.clear();
    else if (parent.rfind("__MACOSX/", 0) == 0) parent.erase(0, 9);
    return logicalPath((localfs::path(parent) / leaf.substr(2)).generic_string());
}

static std::string appleDoubleName(const std::string& target, bool macosx) {
    const localfs::path path(target);
    const auto relative = path.parent_path() / ("._" + path.filename().string());
    return (macosx ? localfs::path("__MACOSX") / relative : relative).generic_string();
}

static bool hasMacMetadata(const localfs::path& source) {
    const auto size = listxattr(source.c_str(), nullptr, 0, XATTR_NOFOLLOW);
    if (size < 0) throw std::runtime_error("无法读取源文件扩展属性");
    if (size == 0) return false;
    std::vector<char> names(static_cast<size_t>(size));
    if (listxattr(source.c_str(), names.data(), names.size(), XATTR_NOFOLLOW) != size) {
        throw std::runtime_error("读取期间源文件扩展属性已变化，请重试");
    }
    for (size_t offset = 0; offset < names.size();) {
        const std::string name(names.data() + offset);
        // 系统生成的来源跟踪由 macOS 管理，不为它单独生成元数据条目。
        if (name != "com.apple.provenance") return true;
        offset += name.size() + 1;
    }
    return false;
}

static localfs::path packMacMetadata(const localfs::path& source, const localfs::path& staging, size_t index) {
    if (localfs::is_symlink(localfs::symlink_status(source)) || !hasMacMetadata(source)) return {};
    const auto metadata = staging / "mac-metadata";
    localfs::create_directories(metadata);
    const auto output = metadata / std::to_string(index);
    if (copyfile(source.c_str(), output.c_str(), nullptr, COPYFILE_XATTR | COPYFILE_PACK | COPYFILE_EXCL | COPYFILE_NOFOLLOW) != 0) {
        throw std::runtime_error("无法保存扩展属性或资源叉，请检查源文件权限与磁盘空间");
    }
    return output;
}

static std::vector<std::pair<std::string, std::string>> compressionInputs(const std::vector<std::string>& paths,
    const localfs::path& staging, bool tar, Job* job) {
    std::vector<std::pair<std::string, std::string>> inputs;
    std::map<std::string, localfs::path> entries;
    for (const auto& value : paths) {
        const localfs::path path(value);
        const auto rootName = path.filename().string();
        if (!entries.emplace(rootName, path).second) throw std::runtime_error("所选输入包含同名顶层项目");
        if (!localfs::is_directory(localfs::symlink_status(path))) continue;
        for (const auto& entry : localfs::recursive_directory_iterator(path)) {
            checkCancellation(job);
            entries.emplace((localfs::path(rootName) / entry.path().lexically_relative(path)).generic_string(), entry.path());
        }
    }
    size_t index = 0;
    for (const auto& [name, path] : entries) {
        checkCancellation(job);
        const auto packed = packMacMetadata(path, staging, index);
        if (!packed.empty()) {
            const auto alias = appleDoubleName(name, !tar);
            if (entries.count(alias)) throw std::runtime_error("输入包含与 macOS 元数据条目重名的文件，请调整名称后重试");
            // BSD tar 需要元数据紧邻其目标条目，顺序不能按物理暂存路径排序。
            inputs.emplace_back(packed.string(), alias);
        }
        auto input = path;
        if (localfs::is_directory(localfs::symlink_status(path))) {
            input = staging / "directory-entries" / std::to_string(index);
            localfs::create_directories(input);
            struct stat status{};
            if (stat(path.c_str(), &status) != 0 || chmod(input.c_str(), status.st_mode & 0777) != 0) {
                throw std::runtime_error("无法暂存目录权限");
            }
            const struct timespec times[] = {status.st_atimespec, status.st_mtimespec};
            if (utimensat(AT_FDCWD, input.c_str(), times, 0) != 0) throw std::runtime_error("无法暂存目录时间");
        }
        inputs.emplace_back(input.string(), name);
        ++index;
    }
    return inputs;
}

static void compressInputs(BitFileCompressor& compressor, const std::vector<std::pair<std::string, std::string>>& inputs,
    const localfs::path& output, Job* job) {
    BitOutputArchive archive(compressor);
    for (const auto& [path, name] : inputs) {
        checkCancellation(job);
        if (localfs::is_directory(localfs::symlink_status(path))) archive.addItems(std::map<std::string, std::string>{{path, name}});
        else archive.addFile(path, name);
    }
    archive.compressTo(output.string());
}

static bool appleDoubleMagic(const char* bytes, size_t size) {
    static const unsigned char magic[] = {0x00, 0x05, 0x16, 0x07};
    return size >= sizeof(magic) && memcmp(bytes, magic, sizeof(magic)) == 0;
}

class AppleDoubleHeader : public std::streambuf {
    off_type position = 0;
    off_type length = 0;
public:
    char bytes[4]{};
    size_t size = 0;
protected:
    std::streamsize xsputn(const char* data, std::streamsize count) override {
        if (position < static_cast<off_type>(sizeof(bytes))) {
            const auto copied = std::min(static_cast<size_t>(count), sizeof(bytes) - static_cast<size_t>(position));
            memcpy(bytes + position, data, copied);
            size = std::max(size, static_cast<size_t>(position) + copied);
        }
        position += count;
        length = std::max(length, position);
        return count;
    }
    pos_type seekoff(off_type offset, std::ios_base::seekdir way, std::ios_base::openmode) override {
        const auto base = way == std::ios_base::beg ? 0 : way == std::ios_base::cur ? position : length;
        if (offset < -base) return pos_type(off_type(-1));
        position = base + offset;
        return pos_type(position);
    }
    pos_type seekpos(pos_type value, std::ios_base::openmode mode) override {
        return seekoff(static_cast<off_type>(value), std::ios_base::beg, mode);
    }
    int_type overflow(int_type value) override {
        if (!traits_type::eq_int_type(value, traits_type::eof())) {
            const auto byte = traits_type::to_char_type(value);
            xsputn(&byte, 1);
        }
        return traits_type::not_eof(value);
    }
};

static std::map<std::string, std::string> archiveMetadata(BitArchiveReader& reader, Job* job) {
    std::map<std::string, std::string> metadata;
    for (const auto& item : reader.items()) {
        checkCancellation(job);
        if (item.isDir()) continue;
        const auto name = logicalPath(item.path(), true);
        const auto target = appleDoubleTarget(name);
        if (target.empty()) continue;
        AppleDoubleHeader header;
        std::ostream stream(&header);
        reader.extractTo(stream, item.index());
        if (appleDoubleMagic(header.bytes, header.size)) metadata[name] = target;
    }
    return metadata;
}

static void validateAppleDouble(const localfs::path& sidecar, uint64_t size) {
    std::ifstream stream(sidecar, std::ios::binary);
    unsigned char header[26]{};
    stream.read(reinterpret_cast<char*>(header), sizeof(header));
    if (stream.gcount() != sizeof(header) || header[4] != 0 || header[5] != 2 || header[6] != 0 || header[7] != 0) {
        throw std::runtime_error("AppleDouble 元数据头损坏");
    }
    const auto count = static_cast<uint32_t>(header[24]) * 256 + header[25];
    const uint64_t tableEnd = sizeof(header) + static_cast<uint64_t>(count) * 12;
    if (tableEnd > size) throw std::runtime_error("AppleDouble 元数据条目表截断");
    for (uint32_t index = 0; index < count; ++index) {
        unsigned char entry[12]{};
        stream.read(reinterpret_cast<char*>(entry), sizeof(entry));
        auto number = [&](size_t offset) {
            return (static_cast<uint64_t>(entry[offset]) << 24) | (static_cast<uint64_t>(entry[offset + 1]) << 16) |
                (static_cast<uint64_t>(entry[offset + 2]) << 8) | entry[offset + 3];
        };
        const auto offset = number(4);
        const auto length = number(8);
        if (stream.gcount() != sizeof(entry) || offset < tableEnd || offset > size || length > size - offset) {
            throw std::runtime_error("AppleDouble 元数据条目超出文件边界");
        }
    }
}

static void restoreMacMetadata(const localfs::path& staging, const std::vector<BitArchiveItemInfo>& items, Job* job) {
    std::set<std::string> targets;
    for (const auto& item : items) targets.insert(logicalPath(item.path(), true));
    for (const auto& item : items) {
        checkCancellation(job);
        if (item.isDir()) continue;
        const auto name = logicalPath(item.path(), true);
        const auto targetName = appleDoubleTarget(name);
        if (targetName.empty() || !targets.count(targetName)) continue;
        const auto sidecar = staging / name;
        const auto target = staging / targetName;
        struct stat sourceStatus{}, targetStatus{};
        if (lstat(sidecar.c_str(), &sourceStatus) != 0 || !S_ISREG(sourceStatus.st_mode) ||
            lstat(target.c_str(), &targetStatus) != 0 || (!S_ISREG(targetStatus.st_mode) && !S_ISDIR(targetStatus.st_mode))) continue;
        std::ifstream stream(sidecar, std::ios::binary);
        char bytes[4]{};
        stream.read(bytes, sizeof(bytes));
        if (!appleDoubleMagic(bytes, static_cast<size_t>(stream.gcount()))) continue;
        validateAppleDouble(sidecar, static_cast<uint64_t>(sourceStatus.st_size));
        if (chmod(target.c_str(), (targetStatus.st_mode & 0777) | 0600) != 0) throw std::runtime_error("无法准备扩展属性恢复");
        const int restored = copyfile(sidecar.c_str(), target.c_str(), nullptr, COPYFILE_XATTR | COPYFILE_UNPACK | COPYFILE_NOFOLLOW);
        const int modeRestored = chmod(target.c_str(), targetStatus.st_mode & 0777);
        if (restored != 0 || modeRestored != 0) throw std::runtime_error("macOS 元数据损坏或无法恢复扩展属性与资源叉");
        localfs::remove(sidecar);
        auto parent = sidecar.parent_path();
        while (parent != staging && localfs::is_empty(parent)) {
            localfs::remove(parent);
            parent = parent.parent_path();
        }
    }
}

// 链接最后创建，解码器只写入普通文件，避免利用链接条目重定向后续写入。
static std::string extractedPath(const BitArchiveItemInfo& item) {
    return logicalPath(item.path(), true);
}

static localfs::path validateLinkTarget(const std::string& name, const std::map<std::string, std::string>& links) {
    std::vector<std::string> resolved;
    for (const auto& part : localfs::path(name).parent_path()) resolved.push_back(part.string());
    std::deque<std::string> pending;
    for (const auto& part : localfs::path(links.at(name))) pending.push_back(part.string());
    unsigned int expanded = 0;
    while (!pending.empty()) {
        const auto part = pending.front();
        pending.pop_front();
        if (part.empty() || part == ".") continue;
        if (part == "..") {
            if (resolved.empty()) throw std::runtime_error("链接目标超出解压目录");
            resolved.pop_back();
            continue;
        }
        localfs::path candidate;
        for (const auto& parent : resolved) candidate /= parent;
        candidate /= part;
        const auto link = links.find(candidate.generic_string());
        if (link == links.end()) resolved.push_back(part);
        else {
            if (++expanded > 40) throw std::runtime_error("符号链接存在循环或层级过深");
            std::vector<std::string> parts;
            for (const auto& component : localfs::path(link->second)) parts.push_back(component.string());
            for (auto iterator = parts.rbegin(); iterator != parts.rend(); ++iterator) pending.push_front(*iterator);
        }
    }
    localfs::path result;
    for (const auto& part : resolved) result /= part;
    return result;
}

class ExtractionPermissions {
    struct DirectoryMode { int descriptor; mode_t original; mode_t desired; };
    std::vector<DirectoryMode> directories;
    bool committed = false;
public:
    ~ExtractionPermissions() {
        if (!committed) rollback();
        for (const auto& entry : directories) close(entry.descriptor);
    }
    void remember(const BitArchiveItemInfo& item, const localfs::path& target) {
        if (item.isSymLink() || !item.itemProperty(BitProperty::HardLink).isEmpty()) return;
        const auto posix = item.itemProperty(BitProperty::PosixAttrib);
        const auto attributes = item.attributes();
        if (!posix.isUInt32() && !(attributes & 0x8000)) return;
        // 仅恢复普通 rwx 权限位，归档不能赋予 setuid/setgid 权限。
        const mode_t mode = (posix.isUInt32() ? posix.getUInt32() : attributes >> 16U) & 0777;
        if (!item.isDir()) {
            if (chmod(target.c_str(), mode) != 0) throw std::runtime_error("无法恢复文件权限");
            return;
        }
        const int descriptor = open(target.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (descriptor < 0) throw std::runtime_error("无法打开待恢复权限的文件夹");
        struct stat status{};
        if (fstat(descriptor, &status) != 0) { close(descriptor); throw std::runtime_error("无法读取文件夹权限"); }
        directories.push_back({descriptor, static_cast<mode_t>(status.st_mode & 0777), mode});
    }
    void apply() {
        for (const auto& entry : directories) {
            if (fchmod(entry.descriptor, entry.desired) != 0) {
                rollback();
                throw std::runtime_error("无法恢复文件夹权限");
            }
        }
    }
    void rollback() noexcept {
        for (const auto& entry : directories) fchmod(entry.descriptor, entry.original);
    }
    void commit() { committed = true; }
};

static void extractSafely(BitArchiveReader& reader, const localfs::path& staging,
    const uint32_t* indices, int count, Job* job, ExtractionPermissions& permissions) {
    const auto items = reader.items();
    std::map<std::string, const BitArchiveItemInfo*> names;
    std::map<std::string, std::string> links;
    std::map<std::string, std::string> hardLinks;
    std::set<uint32_t> selected;
    for (int index = 0; index < count; ++index) selected.insert(indices[index]);
    for (const auto& item : items) {
        checkCancellation(job);
        validateEntry(item, true);
        const auto name = extractedPath(item);
        if (name.empty()) { if (!item.isDir()) throw std::runtime_error("归档包含空文件路径"); continue; }
        if (!names.emplace(name, &item).second) throw std::runtime_error("归档存在重复路径，无法安全解压");
        if (count == 0) selected.insert(item.index());
        const auto hard = item.itemProperty(BitProperty::HardLink);
        if (hard.isString()) hardLinks[name] = logicalPath(hard.getString());
        if (!item.isSymLink()) continue;
        const auto property = item.itemProperty(BitProperty::SymLink);
        std::string target;
        if (property.isString()) target = property.getString();
        else {
            if (item.size() > 65536) throw std::runtime_error("符号链接目标过长");
            std::vector<byte_t> buffer;
            reader.extractTo(buffer, item.index());
            target.assign(buffer.begin(), buffer.end());
        }
        std::replace(target.begin(), target.end(), '\\', '/');
        if (target.empty() || target.size() > 65536 || target.find('\0') != std::string::npos ||
            localfs::path(target).is_absolute() || (target.size() > 1 && target[1] == ':')) {
            throw std::runtime_error("归档包含不安全的符号链接目标");
        }
        links[name] = target;
    }
    for (const auto& [name, item] : names) {
        auto parent = localfs::path(name).parent_path();
        while (!parent.empty()) {
            const auto found = names.find(parent.generic_string());
            if (found != names.end() && (!found->second->isDir() || links.count(parent.generic_string()))) {
                throw std::runtime_error("归档条目不能位于文件或链接之下");
            }
            parent = parent.parent_path();
        }
    }
    for (const auto& [name, target] : links) validateLinkTarget(name, links);
    // 硬链接必须指向归档中的普通文件，选中链接时补齐其数据依赖。
    std::map<std::string, std::string> hardTargets;
    for (const auto& [name, target] : hardLinks) {
        auto resolved = target;
        std::set<std::string> visited{name};
        while (hardLinks.count(resolved)) {
            if (!visited.insert(resolved).second) throw std::runtime_error("硬链接存在循环");
            resolved = hardLinks.at(resolved);
        }
        const auto found = names.find(resolved);
        if (found == names.end() || found->second->isDir() || links.count(resolved)) {
            throw std::runtime_error("硬链接目标必须是归档中的普通文件");
        }
        hardTargets[name] = resolved;
        if (selected.count(names.at(name)->index())) selected.insert(found->second->index());
    }
    for (const auto& [name, item] : names) {
        const auto target = appleDoubleTarget(name);
        const auto found = names.find(target);
        if (found != names.end() && selected.count(found->second->index())) selected.insert(item->index());
    }
    for (const auto index : selected) if (index >= items.size()) throw std::runtime_error("无效的解压条目索引");
    uint64_t total = 0;
    std::vector<uint32_t> regular;
    for (const auto& item : items) {
        if (selected.count(item.index())) checkOutputBudget(item.size(), total, job);
        const auto name = extractedPath(item);
        if (selected.count(item.index()) && !links.count(name) && !hardLinks.count(name)) regular.push_back(item.index());
    }
    if (!regular.empty()) reader.extractTo(staging.string(), regular);
    if (job->outputLimit) {
        total = 0;
        for (const auto& entry : localfs::recursive_directory_iterator(staging)) {
            if (entry.is_regular_file()) checkOutputBudget(entry.file_size(), total, job);
        }
    }
    for (const auto& [name, target] : hardTargets) {
        if (!selected.count(names.at(name)->index())) continue;
        checkCancellation(job);
        localfs::create_directories((staging / name).parent_path());
        if (link((staging / target).c_str(), (staging / name).c_str()) != 0) throw std::runtime_error("无法创建硬链接");
    }
    restoreMacMetadata(staging, items, job);
    for (const auto& [name, target] : links) {
        if (!selected.count(names.at(name)->index())) continue;
        checkCancellation(job);
        localfs::create_directories((staging / name).parent_path());
        if (symlink(target.c_str(), (staging / name).c_str()) != 0) throw std::runtime_error("无法创建符号链接");
    }
    for (const auto& item : items) {
        if (selected.count(item.index()) && localfs::symlink_status(staging / extractedPath(item)).type() != localfs::file_type::not_found) {
            permissions.remember(item, staging / extractedPath(item));
        }
    }
}

class MutationConflict : public std::runtime_error {
public:
    std::vector<std::string> paths;
    explicit MutationConflict(std::vector<std::string> values)
        : std::runtime_error("添加的文件与压缩包内文件重名"), paths(std::move(values)) {}
};

// 通过目录描述符访问目标，防止合并时沿符号链接写到目标目录以外。
class ExtractionDirectory {
public:
    int descriptor;
    std::shared_ptr<ExtractionDirectory> parent;
    localfs::path root;
    std::string name;
    struct stat identity{};

    ExtractionDirectory(const localfs::path& path) : root(path) {
        descriptor = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        initialize();
    }
    ExtractionDirectory(std::shared_ptr<ExtractionDirectory> owner, const std::string& child)
        : parent(std::move(owner)), name(child) {
        descriptor = openat(parent->descriptor, name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        initialize();
    }
    ~ExtractionDirectory() {
        if (descriptor >= 0) { flock(descriptor, LOCK_UN); close(descriptor); }
    }
    void verify() const {
        struct stat current{};
        if (parent) parent->verify();
        const int status = parent
            ? fstatat(parent->descriptor, name.c_str(), &current, AT_SYMLINK_NOFOLLOW)
            : lstat(root.c_str(), &current);
        if (status != 0 || current.st_dev != identity.st_dev || current.st_ino != identity.st_ino || !S_ISDIR(current.st_mode)) {
            throw std::runtime_error("解压目标目录已变化，请检查后重试");
        }
    }
private:
    void initialize() {
        if (descriptor < 0) throw std::runtime_error("无法安全打开解压目标目录");
        if (fstat(descriptor, &identity) != 0 || flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
            close(descriptor);
            descriptor = -1;
            throw std::runtime_error("解压目标正在被其他任务写入，请稍后重试");
        }
    }
};

static bool sameExtractedFile(const struct stat& left, const struct stat& right, bool renamed = false) {
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
        left.st_mode == right.st_mode && left.st_size == right.st_size &&
        left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec &&
        (renamed || (left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec));
}

class ExtractionConflict : public std::runtime_error {
public:
    std::vector<std::string> paths;
    std::string version;
    ExtractionConflict(std::vector<std::string> values, std::string snapshot)
        : std::runtime_error("解压目标存在同名项目，请选择处理方式"), paths(std::move(values)), version(std::move(snapshot)) {}
};

static std::string extractionStatus(const struct stat& status) {
    std::ostringstream version;
    version << status.st_dev << ',' << status.st_ino << ',' << status.st_mode;
    if (!S_ISDIR(status.st_mode)) {
        version << ',' << status.st_size << ',' << status.st_mtimespec.tv_sec << ',' << status.st_mtimespec.tv_nsec
            << ',' << status.st_ctimespec.tv_sec << ',' << status.st_ctimespec.tv_nsec;
    }
    return version.str();
}

static void extractionVersions(const localfs::path& source, const std::shared_ptr<ExtractionDirectory>& directory,
    std::map<std::string, std::string>& versions, Job* job, const localfs::path& relative = {}) {
    for (const auto& entry : localfs::directory_iterator(source)) {
        checkCancellation(job);
        const auto name = entry.path().filename().string();
        const auto key = (relative / name).string();
        struct stat status{};
        if (fstatat(directory->descriptor, name.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno != ENOENT) throw std::runtime_error("无法检查解压目标文件状态");
            versions[key] = "missing";
            continue;
        }
        versions[key] = extractionStatus(status);
        if (S_ISDIR(status.st_mode) && localfs::is_directory(localfs::symlink_status(entry.path()))) {
            auto child = std::make_shared<ExtractionDirectory>(directory, name);
            if (child->identity.st_dev != status.st_dev || child->identity.st_ino != status.st_ino) {
                throw std::runtime_error("解压目标目录已变化，请检查后重试");
            }
            extractionVersions(entry.path(), child, versions, job, relative / name);
        }
    }
}

struct ExtractionMove {
    localfs::path source;
    std::shared_ptr<ExtractionDirectory> directory;
    std::string name;
    struct stat expected{};
    struct stat published{};
    bool replace = false;
    bool committed = false;
};

// 先生成完整计划，再发布。合并已有目录时，保留其余文件与目录自身的元数据。
static void planExtraction(const localfs::path& source, const std::shared_ptr<ExtractionDirectory>& directory,
    uint32_t policy, const std::map<std::string, std::string>& versions, std::vector<ExtractionMove>& moves, std::vector<std::string>& conflicts, Job* job,
    const localfs::path& relative = {}) {
    std::set<std::string> reserved;
    for (const auto& entry : localfs::directory_iterator(source)) reserved.insert(entry.path().filename().string());
    for (const auto& entry : localfs::directory_iterator(source)) {
        checkCancellation(job);
        const auto original = entry.path().filename().string();
        auto name = original;
        struct stat existing{};
        const int status = fstatat(directory->descriptor, name.c_str(), &existing, AT_SYMLINK_NOFOLLOW);
        if (status != 0 && errno != ENOENT) throw std::runtime_error("无法读取目标文件状态，请检查目录权限");
        const bool exists = status == 0;
        const auto snapshot = versions.at((relative / original).string());
        if (snapshot != (exists ? extractionStatus(existing) : "missing")) {
            throw std::runtime_error("规划期间解压目标已变化，请检查后重试");
        }
        const bool sourceDirectory = localfs::is_directory(localfs::symlink_status(entry.path()));
        if (exists && policy != 0 && policy != 2 && sourceDirectory && S_ISDIR(existing.st_mode)) {
            auto child = std::make_shared<ExtractionDirectory>(directory, name);
            if (child->identity.st_dev != existing.st_dev || child->identity.st_ino != existing.st_ino) {
                throw std::runtime_error("合并目录已变化，请检查后重试");
            }
            planExtraction(entry.path(), child, policy, versions, moves, conflicts, job, relative / original);
            continue;
        }
        if (exists && policy == 1) continue;
        if (exists && policy == 2) {
            const auto base = sourceDirectory ? original : entry.path().stem().string();
            const auto extension = sourceDirectory ? "" : entry.path().extension().string();
            unsigned int index = 2;
            do {
                name = base + " (" + std::to_string(index++) + ")" + extension;
                if (reserved.count(name)) continue;
                if (fstatat(directory->descriptor, name.c_str(), &existing, AT_SYMLINK_NOFOLLOW) != 0) {
                    if (errno == ENOENT) break;
                    throw std::runtime_error("无法检查自动改名的目标位置");
                }
            } while (true);
            reserved.insert(name);
        } else if (exists && (policy != 4 || !localfs::is_regular_file(entry.symlink_status()) || !S_ISREG(existing.st_mode))) {
            conflicts.push_back((relative / original).string());
            continue;
        }
        moves.push_back({entry.path(), directory, name, existing, {}, exists && policy == 4, false});
    }
}

static localfs::path publishedExtractionPath(const localfs::path& path, const localfs::path& source,
    const std::vector<ExtractionMove>& moves, bool* moved = nullptr) {
    for (const auto& move : moves) {
        const auto suffix = path.lexically_relative(move.source);
        if (suffix.empty() || *suffix.begin() == "..") continue;
        std::vector<std::string> parents;
        for (auto directory = move.directory; directory->parent; directory = directory->parent) parents.push_back(directory->name);
        localfs::path output;
        for (auto iterator = parents.rbegin(); iterator != parents.rend(); ++iterator) output /= *iterator;
        if (moved) *moved = true;
        return suffix == "." ? output / move.name : (output / move.name / suffix).lexically_normal();
    }
    return path.lexically_relative(source);
}

static std::vector<localfs::path> preparePublishedLinks(const localfs::path& source, const std::vector<ExtractionMove>& moves) {
    std::map<std::string, std::string> links;
    for (const auto& entry : localfs::recursive_directory_iterator(source)) {
        if (localfs::is_symlink(entry.symlink_status())) links[entry.path().lexically_relative(source).generic_string()] = localfs::read_symlink(entry.path()).generic_string();
    }
    std::vector<localfs::path> published;
    for (const auto& [name, target] : links) {
        bool moved = false;
        const auto output = publishedExtractionPath(source / name, source, moves, &moved);
        if (!moved) continue;
        const auto resolved = validateLinkTarget(name, links);
        const auto destination = publishedExtractionPath(source / resolved, source, moves);
        auto rewritten = destination.lexically_relative(output.parent_path());
        if (rewritten.empty()) rewritten = ".";
        if (unlink((source / name).c_str()) != 0 || symlink(rewritten.c_str(), (source / name).c_str()) != 0) {
            throw std::runtime_error("无法调整自动改名后的符号链接目标");
        }
        published.push_back(output);
    }
    return published;
}

static localfs::path publishExtraction(
    const localfs::path& source, const localfs::path& target, Job* job, StagingDirectory& staging,
    const localfs::path& archive, const struct stat& targetIdentity, ExtractionPermissions& permissions,
    const std::string& archiveVolumes, const localfs::path& outputRelative = {}) {
    ExtractionDirectory stagedRoot(source);
    auto directory = std::make_shared<ExtractionDirectory>(target);
    if (directory->identity.st_dev != targetIdentity.st_dev || directory->identity.st_ino != targetIdentity.st_ino) {
        throw std::runtime_error("解压期间目标目录已变化，请检查后重试");
    }
    std::map<std::string, std::string> versions;
    extractionVersions(source, directory, versions, job);
    std::string version = std::to_string(directory->identity.st_dev) + "," + std::to_string(directory->identity.st_ino);
    for (const auto& [name, status] : versions) version += "\n" + quote(name) + "=" + status;
    if (!job->expectedDestinationVersion.empty() && version != job->expectedDestinationVersion) {
        throw std::runtime_error("确认期间解压目标已变化，请重新发起解压并核对冲突");
    }
    std::vector<ExtractionMove> moves;
    std::vector<std::string> conflicts;
    planExtraction(source, directory, job->extractionPolicy, versions, moves, conflicts, job);
    if (!conflicts.empty()) throw ExtractionConflict(std::move(conflicts), version);
    const auto publishedLinks = preparePublishedLinks(source, moves);
    const auto publishedOutput = outputRelative.empty() ? localfs::path{} : publishedExtractionPath(source / outputRelative, source, moves);
    std::set<std::pair<dev_t, ino_t>> inputs;
    const auto archivePath = localfs::absolute(archive);
    const auto family = volumeFamily(archivePath.filename().string());
    for (const auto& entry : localfs::directory_iterator(archivePath.parent_path())) {
        if (entry.path() != archivePath && (family.empty() || volumeFamily(entry.path().filename().string()) != family)) continue;
        struct stat status{};
        if (stat(entry.path().c_str(), &status) == 0) inputs.emplace(status.st_dev, status.st_ino);
    }
    for (const auto& move : moves) {
        if (move.replace && inputs.count({move.expected.st_dev, move.expected.st_ino})) {
            throw std::runtime_error("解压结果不能替换原压缩包或其分卷，请选择跳过或自动改名");
        }
    }
    std::sort(moves.begin(), moves.end(), [](const auto& left, const auto& right) { return left.source < right.source; });
    try {
        if (volumeVersion(archive.c_str()) != archiveVolumes) throw std::runtime_error("发布期间压缩包或分卷已变化，请重新打开");
        for (auto& move : moves) {
            checkCancellation(job);
            move.directory->verify();
            struct stat current{};
            const int status = fstatat(move.directory->descriptor, move.name.c_str(), &current, AT_SYMLINK_NOFOLLOW);
            if (move.replace && (status != 0 || !sameExtractedFile(move.expected, current))) {
                throw std::runtime_error("待替换文件已变化，请检查后重试");
            }
            if (!move.replace && (status == 0 || errno != ENOENT)) {
                throw std::runtime_error("发布期间出现同名项目，请检查后重试");
            }
            const auto stagedName = move.source.lexically_relative(source);
            if (fstatat(stagedRoot.descriptor, stagedName.c_str(), &move.published, AT_SYMLINK_NOFOLLOW) != 0) throw std::runtime_error("无法读取暂存结果");
            // 交换后旧文件保留在私有暂存目录，直到整组发布成功。
            const unsigned int flags = move.replace ? RENAME_SWAP : RENAME_EXCL;
            if (renameatx_np(stagedRoot.descriptor, stagedName.c_str(), move.directory->descriptor, move.name.c_str(), flags) != 0) {
                throw std::runtime_error("无法保存解压结果，请检查同名项目或目录权限");
            }
            move.committed = true;
            if (move.replace && (fstatat(stagedRoot.descriptor, stagedName.c_str(), &current, AT_SYMLINK_NOFOLLOW) != 0 || !sameExtractedFile(move.expected, current, true))) {
                throw std::runtime_error("替换期间目标文件已变化，请检查后重试");
            }
            if (move.replace && move.expected.st_nlink > 1) {
                // 同一旧 inode 的其他硬链接会随本次交换更新 ctime。
                for (auto& alias : moves) {
                    if (alias.expected.st_dev == move.expected.st_dev && alias.expected.st_ino == move.expected.st_ino) {
                        alias.expected.st_ctimespec = current.st_ctimespec;
                    }
                }
            }
        }
        checkCancellation(job);
        for (const auto& move : moves) move.directory->verify();
        for (const auto& link : publishedLinks) validateMaterializedLink(target / link, target);
        permissions.apply();
        checkCancellation(job);
        if (volumeVersion(archive.c_str()) != archiveVolumes) throw std::runtime_error("发布期间压缩包或分卷已变化，请重新打开");
    } catch (...) {
        permissions.rollback();
        bool restored = true;
        for (auto iterator = moves.rbegin(); iterator != moves.rend(); ++iterator) {
            auto& move = *iterator;
            if (!move.committed) continue;
            const auto stagedName = move.source.lexically_relative(source);
            struct stat current{};
            if (fstatat(move.directory->descriptor, move.name.c_str(), &current, AT_SYMLINK_NOFOLLOW) != 0 ||
                !sameExtractedFile(move.published, current, true) ||
                renameatx_np(move.directory->descriptor, move.name.c_str(), stagedRoot.descriptor, stagedName.c_str(),
                             move.replace ? RENAME_SWAP : RENAME_EXCL) != 0) {
                restored = false;
            }
        }
        if (!restored) {
            // 回滚受外部写入阻挡时，保留旧文件，避免清理暂存目录造成数据丢失。
            staging.preserve = true;
            throw std::runtime_error("目标被并发修改，部分结果需手动核对。原文件与暂存结果保留于 " + staging.currentPath().string());
        }
        throw;
    }
    return publishedOutput;
}

static void applyArchiveMutation(BitArchiveEditor& editor, const std::vector<BitArchiveItemInfo>& items,
    const std::string& action, const char* itemPath, const char* destination,
    const char* const* inputs, int inputCount, const localfs::path& archive, const localfs::path& staging, Job* job,
    const std::map<std::string, std::string>& metadata) {
    if (action == "update") {
        const auto original = std::find_if(items.begin(), items.end(), [&](const auto& item) { return item.path() == itemPath; });
        const auto edited = staging / "edited-data";
        if (copyfile(destination, edited.c_str(), nullptr, COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW) != 0) {
            throw std::runtime_error("无法暂存待回写文件");
        }
        if (!localfs::is_regular_file(localfs::symlink_status(edited))) throw std::runtime_error("待回写内容必须是普通文件");
        if (original != items.end()) {
            const auto posix = original->itemProperty(BitProperty::PosixAttrib);
            const auto attributes = original->attributes();
            if (posix.isUInt32() || (attributes & 0x8000)) {
                const mode_t mode = (posix.isUInt32() ? posix.getUInt32() : attributes >> 16U) & 0777;
                if (chmod(edited.c_str(), mode) != 0) throw std::runtime_error("无法保留包内文件权限");
            }
        }
        editor.updateItem(std::string(itemPath), edited.string());
        const auto packed = packMacMetadata(destination, staging, 0);
        if (!packed.empty()) {
            auto alias = appleDoubleName(itemPath, true);
            for (const auto& [name, target] : metadata) if (target == itemPath) { alias = name; break; }
            const auto found = std::find_if(items.begin(), items.end(), [&](const auto& item) { return item.path() == alias; });
            if (found == items.end()) editor.addFile(packed.string(), alias);
            else {
                if (!metadata.count(alias)) throw std::runtime_error("元数据条目与已有普通文件重名");
                editor.updateItem(found->index(), packed.string());
            }
        }
        return;
    }
    std::map<std::string, const BitArchiveItemInfo*> existing;
    std::set<std::string> occupied;
    for (const auto& item : items) {
        validateEntry(item);
        const auto name = logicalPath(item.path(), true);
        if (name.empty()) continue;
        if (!existing.emplace(name, &item).second) throw std::runtime_error("压缩包存在重复路径，已停止修改");
        auto path = name;
        while (!path.empty()) {
            occupied.insert(path);
            const auto slash = path.find_last_of('/');
            if (slash == std::string::npos) break;
            path.erase(slash);
        }
    }
    auto checkParents = [&](std::string name) {
        for (auto slash = name.find_last_of('/'); slash != std::string::npos; slash = name.find_last_of('/')) {
            name.erase(slash);
            const auto parent = existing.find(name);
            if (parent != existing.end() && !parent->second->isDir()) throw std::runtime_error("目标路径的父级是文件");
        }
    };
    if (action == "remove") {
        std::set<std::string> selected;
        for (int i = 0; i < inputCount; ++i) selected.insert(logicalPath(inputs[i]));
        int count = 0;
        for (const auto& [name, item] : existing) {
            const auto sidecar = metadata.find(name);
            if (selectedPath(name, selected) || (sidecar != metadata.end() && selectedPath(sidecar->second, selected))) {
                editor.deleteItem(item->index()); ++count;
            }
        }
        if (!count) throw std::runtime_error("未找到需要删除的条目");
        return;
    }
    if (action == "rename") {
        const auto from = logicalPath(itemPath);
        const auto to = logicalPath(destination);
        checkParents(to);
        if (from == to) throw std::runtime_error("新旧名称相同");
        if (occupied.count(to) || to.compare(0, from.size() + 1, from + "/") == 0) {
            throw std::runtime_error("目标名称已存在，或位于原目录内部");
        }
        int count = 0;
        for (const auto& [name, item] : existing) {
            const auto sidecar = metadata.find(name);
            std::string renamed;
            if (sidecar != metadata.end() && selectedPath(sidecar->second, {from})) {
                renamed = appleDoubleName(to + sidecar->second.substr(from.size()), name.rfind("__MACOSX/", 0) == 0);
            } else if (name == from || name.compare(0, from.size() + 1, from + "/") == 0) {
                renamed = to + name.substr(from.size());
            }
            if (!renamed.empty() && renamed != name) {
                if (occupied.count(renamed)) throw std::runtime_error("重命名后的元数据条目与已有文件重名");
                editor.renameItem(item->index(), renamed); ++count;
            }
        }
        if (!count) throw std::runtime_error("未找到需要重命名的条目");
        return;
    }
    if (action == "mkdir") {
        const auto name = logicalPath(destination);
        checkParents(name);
        if (occupied.count(name)) throw std::runtime_error("目标名称已存在");
        const auto empty = staging / "new-folder";
        localfs::create_directory(empty);
        editor.addItems(std::map<std::string, std::string>{{empty.string(), name}});
        return;
    }
    if (action != "add" && action != "addReplace") throw std::runtime_error("未知压缩包修改操作");
    if (inputCount <= 0) throw std::runtime_error("请选择需要添加的文件或文件夹");
    const auto prefix = logicalPath(itemPath, true);
    std::map<std::string, std::string> files;
    std::map<std::string, std::string> emptyDirectories;
    std::map<std::string, std::string> metadataSources;
    std::set<std::string> incoming;
    std::set<std::string> directories;
    std::set<std::string> emptyNames;
    std::vector<std::string> conflicts;
    auto collect = [&](const localfs::path& source, const std::string& requested) {
        checkCancellation(job);
        const auto name = logicalPath(requested);
        checkParents(name);
        if (localfs::is_symlink(localfs::symlink_status(source))) throw std::runtime_error("添加暂不支持符号链接，请选择实际文件或目录");
        const bool directory = localfs::is_directory(source);
        metadataSources[source.string()] = name;
        const auto found = existing.find(name);
        if (directory) {
            if (incoming.count(name)) throw std::runtime_error("所选输入的文件与目录同名");
            directories.insert(name);
            if (found != existing.end() && !found->second->isDir()) throw std::runtime_error("添加的目录与已有文件同名");
            if (localfs::is_empty(source) && !occupied.count(name) && emptyNames.insert(name).second) emptyDirectories[source.string()] = name;
        } else {
            if (!localfs::is_regular_file(source)) throw std::runtime_error("添加只支持普通文件和目录");
            if (directories.count(name)) throw std::runtime_error("所选输入的文件与目录同名");
            if (!incoming.insert(name).second) throw std::runtime_error("所选输入包含重复的目标文件名");
            if (occupied.count(name) && (found == existing.end() || found->second->isDir())) throw std::runtime_error("添加的文件与已有目录同名");
            if (found != existing.end()) conflicts.push_back(name);
            files[source.string()] = name;
        }
    };
    for (int i = 0; i < inputCount; ++i) {
        const auto source = localfs::absolute(inputs[i]);
        if (localfs::is_symlink(localfs::symlink_status(source))) throw std::runtime_error("请选择实际文件或目录");
        const auto canonical = localfs::canonical(source);
        if (canonical == archive) throw std::runtime_error("不能将压缩包添加到自身");
        const auto rootName = (prefix.empty() ? "" : prefix + "/") + source.filename().string();
        if (localfs::is_directory(source)) {
            const auto relative = archive.lexically_relative(canonical);
            if (!relative.empty() && *relative.begin() != "..") throw std::runtime_error("所选目录包含当前压缩包，已停止递归添加");
            collect(source, rootName);
            for (const auto& child : localfs::recursive_directory_iterator(source)) {
                collect(child.path(), rootName + "/" + child.path().lexically_relative(source).generic_string());
            }
        } else collect(source, rootName);
    }
    if (!conflicts.empty() && action == "add") throw MutationConflict(std::move(conflicts));
    size_t metadataIndex = 0;
    for (const auto& [source, name] : metadataSources) {
        checkCancellation(job);
        const auto packed = packMacMetadata(source, staging, metadataIndex++);
        std::vector<std::string> oldAliases;
        for (const auto& [alias, target] : metadata) if (target == name) oldAliases.push_back(alias);
        if (packed.empty()) {
            if (!localfs::is_directory(source) && action == "addReplace") {
                for (const auto& alias : oldAliases) editor.deleteItem(existing.at(alias)->index());
            }
            continue;
        }
        const auto alias = oldAliases.empty() ? appleDoubleName(name, true) : oldAliases.front();
        checkParents(alias);
        if (incoming.count(alias) || (occupied.count(alias) && !metadata.count(alias))) {
            throw std::runtime_error("元数据条目与待添加文件或已有普通文件重名");
        }
        files[packed.string()] = alias;
        for (size_t index = 1; index < oldAliases.size(); ++index) editor.deleteItem(existing.at(oldAliases[index])->index());
    }
    for (const auto& [source, name] : files) {
        const auto found = existing.find(name);
        if (found == existing.end()) editor.addFile(source, name);
        else editor.updateItem(found->second->index(), source);
    }
    if (!emptyDirectories.empty()) editor.addItems(emptyDirectories);
}

extern "C" {
__attribute__((visibility("default"))) Job* f7_job_create() { return new Job(); }
__attribute__((visibility("default"))) void f7_job_destroy(Job* job) { delete job; }
__attribute__((visibility("default"))) void f7_job_cancel(Job* job) { job->cancelled = true; }
__attribute__((visibility("default"))) void f7_job_codepage(Job* job, uint32_t codePage) {
    job->codePage = codePage;
}

__attribute__((visibility("default"))) void f7_job_volume_size(Job* job, uint64_t size) {
    job->volumeSize = size;
}

__attribute__((visibility("default"))) void f7_job_extraction_options(Job* job, uint32_t policy, const char* expectedVersion) {
    job->extractionPolicy = policy;
    job->expectedDestinationVersion = expectedVersion;
}

__attribute__((visibility("default"))) void f7_job_output_limit(Job* job, uint64_t bytes) {
    job->outputLimit = bytes;
}

__attribute__((visibility("default"))) void f7_job_export_options(Job* job, const char* path, const char* version) {
    job->exportPath = path;
    job->exportVersion = version;
}

__attribute__((visibility("default"))) void f7_free(char* value) { free(value); }

__attribute__((visibility("default"))) char* f7_job_progress(Job* job) {
    std::lock_guard<std::mutex> guard(job->mutex);
    return result("{\"total\":" + std::to_string(job->total.load()) +
        ",\"completed\":" + std::to_string(job->completed.load()) +
        ",\"file\":" + quote(job->currentFile) + "}");
}

// operation 为 list / extract / extractHere / extractSmart / export / test / compress，解压操作可加 Flat 后缀，所有字符串使用 UTF-8。
__attribute__((visibility("default"))) char* f7_run(
    Job* job, const char* engine, const char* operation, const char* archive,
    const char* destination, const char* password, const char* format, int level,
    const char* const* inputs, int inputCount, const uint32_t* indices, int indexCount) {
    bool multiVolume = false;
    try {
        checkCancellation(job);
        Bit7zLibrary library(engine);
        std::string op(operation);
        if (op == "compress") {
            if (inputCount <= 0) throw std::runtime_error("请选择需要压缩的文件或文件夹");
            localfs::path target = localfs::absolute(archive);
            if (localfs::exists(target)) throw std::runtime_error("目标文件已存在，请使用新文件名");
            const std::map<std::string, const BitInOutFormat*> formats = {
                {"zip", &BitFormat::Zip}, {"zip-aes256", &BitFormat::Zip},
                {"7z", &BitFormat::SevenZip}, {"7z-visible", &BitFormat::SevenZip},
                {"tar", &BitFormat::Tar}, {"gz", &BitFormat::GZip},
                {"xz", &BitFormat::Xz}, {"bz2", &BitFormat::BZip2},
                {"tar.gz", &BitFormat::GZip}, {"tar.bz2", &BitFormat::BZip2},
                {"tar.xz", &BitFormat::Xz}
            };
            const auto found = formats.find(format);
            if (found == formats.end()) throw std::runtime_error("不支持的压缩格式");
            const auto& outputFormat = *found->second;
            if (job->volumeSize && outputFormat != BitFormat::Zip && outputFormat != BitFormat::SevenZip) {
                throw std::runtime_error("分卷创建仅支持 ZIP 和 7z");
            }
            checkOutputGroup(target);
            const bool tarStream = std::string(format).rfind("tar.", 0) == 0;
            const bool singleFile = !tarStream && !outputFormat.hasFeature(FormatFeatures::MultipleFiles);
            if (singleFile && inputCount != 1) throw std::runtime_error("所选格式仅支持压缩一个普通文件");
            if (password[0] && !outputFormat.hasFeature(FormatFeatures::Encryption)) {
                throw std::runtime_error("所选格式不支持密码加密");
            }
            std::vector<std::string> paths;
            for (int i = 0; i < inputCount; ++i) {
                localfs::path source = localfs::absolute(inputs[i]);
                const auto sourceStatus = localfs::symlink_status(source);
                if (!localfs::is_symlink(sourceStatus)) source = localfs::canonical(source);
                if (singleFile && !localfs::is_regular_file(sourceStatus)) {
                    throw std::runtime_error("所选格式仅支持压缩一个普通文件");
                }
                if (localfs::is_directory(sourceStatus)) {
                    auto relative = localfs::weakly_canonical(target).lexically_relative(source);
                    if (!relative.empty() && *relative.begin() != "..") {
                        throw std::runtime_error("请将压缩包保存到所选文件夹外，避免递归压缩自身");
                    }
                }
                paths.push_back(source.string());
            }
            StagingDirectory staging(target.parent_path());
            const auto packedInputs = singleFile ? std::vector<std::pair<std::string, std::string>>{} :
                compressionInputs(paths, staging.path, tarStream || outputFormat == BitFormat::Tar, job);
            const bool sevenZip = outputFormat == BitFormat::SevenZip;
            BitFileCompressor compressor(library, outputFormat);
            callbacks(compressor, job);
            compressor.setStoreSymbolicLinks(true);
            compressor.setCompressionLevel(static_cast<BitCompressionLevel>(level));
            if (password[0]) compressor.setPassword(password, sevenZip && std::string(format) != "7z-visible");
            if (std::string(format) == "zip-aes256") compressor.setFormatProperty(L"em", L"AES256");
            compressor.setVolumeSize(job->volumeSize);
            const auto output = job->volumeSize ? staging.path / "volumes" / target.filename() :
                staging.path / (std::string("archive.") + (tarStream ? "tar." : "") + outputFormat.extension());
            if (job->volumeSize) localfs::create_directory(output.parent_path());
            if (tarStream) {
                const auto tar = staging.path / "archive.tar";
                BitFileCompressor packer(library, BitFormat::Tar);
                callbacks(packer, job);
                packer.setStoreSymbolicLinks(true);
                compressInputs(packer, packedInputs, tar, job);
                checkCancellation(job);
                paths = {tar.string()};
            }
            if (singleFile || tarStream) compressor.compress(paths, output.string());
            else compressInputs(compressor, packedInputs, output, job);
            checkCancellation(job);
            // 发布期间锁住目标目录，避免本程序并发创建的卷组交错。
            ArchiveLock directoryLock(localfs::canonical(target.parent_path()).c_str());
            checkCancellation(job);
            checkOutputGroup(target);
            if (job->volumeSize) publishContents(output.parent_path(), target.parent_path(), job);
            else publish(output, target);
            const auto first = job->volumeSize ? localfs::path(target.string() + ".001") : target;
            return result("{\"ok\":true,\"path\":" + quote(first.string()) + "}");
        }
        const auto name = localfs::path(archive).filename().string();
        static const std::regex volumeName(R"((\.[0-9]{3,}|\.part[0-9]+\.rar|\.z[0-9]{2,}|\.r[0-9]{2,})$)", std::regex::icase);
        multiVolume = std::regex_search(name, volumeName);
        static const std::regex zipName(R"(\.zip$)", std::regex::icase);
        auto firstZipVolume = localfs::path(archive);
        firstZipVolume.replace_extension(".z01");
        multiVolume = multiVolume || (std::regex_search(name, zipName) && localfs::exists(firstZipVolume));
        static const std::regex numberedName(R"(^[\s\S]*(?:\.([0-9]{3,})|\.part([0-9]+)\.rar)$)", std::regex::icase);
        std::smatch number;
        if (std::regex_match(name, number, numberedName)) {
            const auto digits = number[1].matched ? number[1].str() : number[2].str();
            const auto first = digits.find_first_not_of('0');
            if (first == std::string::npos || digits.substr(first) != "1") {
                throw std::runtime_error("请从第一个分卷打开（.001 或 .part1.rar），并将全部分卷放在同一文件夹");
            }
        }
        const auto initialVersion = archiveVersion(archive);
        const auto initialVolumes = volumeVersion(archive);
        if (op == "export" && (job->exportVersion.empty() ||
            (job->exportVersion != initialVersion && job->exportVersion != initialVolumes))) {
            throw std::runtime_error("拖出期间压缩包已变化，请重新打开后再操作");
        }
        ZipEncodingScope encoding(engine, archive, job->codePage);
        // 展开封装层后，浏览、选中解压与测试共用同一内层归档和索引。
        std::vector<std::unique_ptr<StagingDirectory>> intermediates;
        auto opened = std::make_unique<BitArchiveReader>(library, archive, BitFormat::Auto, password);
        callbacks(*opened, job);
        multiVolume = opened->isMultiVolume();
        const auto volumeCount = opened->volumesCount();
        validateVolumes(*opened);
        localfs::path readPath = archive;
        if (opened->detectedFormat() == BitFormat::Split) {
            multiVolume = true;
            readPath = unpackSingleArchive(*opened, job, intermediates);
            if (job->codePage == 0) encoding.detectArchive(readPath.c_str());
            opened = std::make_unique<BitArchiveReader>(library, readPath.string(), BitFormat::Auto, password);
            callbacks(*opened, job);
        }
        const auto readVersion = multiVolume ? initialVolumes : initialVersion;
        std::string archiveName = readPath.filename().string();
        std::transform(archiveName.begin(), archiveName.end(), archiveName.begin(),
            [](unsigned char value) { return static_cast<char>(std::tolower(value)); });
        const std::vector<std::string> tarSuffixes = {".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz"};
        const bool namedTar = std::any_of(tarSuffixes.begin(), tarSuffixes.end(), [&](const auto& suffix) {
            return archiveName.size() >= suffix.size() && archiveName.compare(archiveName.size() - suffix.size(), suffix.size(), suffix) == 0;
        });
        const auto& outerFormat = opened->detectedFormat();
        if (namedTar && (outerFormat == BitFormat::GZip || outerFormat == BitFormat::BZip2 || outerFormat == BitFormat::Xz)) {
            const auto tar = unpackSingleArchive(*opened, job, intermediates);
            opened = std::make_unique<BitArchiveReader>(library, tar.string(), BitFormat::Tar, password);
            callbacks(*opened, job);
        }
        auto& reader = *opened;
        if (op == "list") {
            auto items = archiveItems(reader, job);
            if (volumeVersion(archive) != initialVolumes) throw std::runtime_error("读取期间压缩包或分卷已变化，请重新打开");
            const auto entries = reader.items();
            const bool containsLinks = std::any_of(entries.begin(), entries.end(), [](const auto& item) {
                return item.isSymLink() || !item.itemProperty(BitProperty::HardLink).isEmpty();
            });
            const bool editable = !multiVolume && !containsLinks && (reader.detectedFormat() == BitFormat::Zip || reader.detectedFormat() == BitFormat::SevenZip);
            return result("{\"ok\":true,\"codePage\":" + std::to_string(encoding.codePage()) + ",\"volumes\":" + std::to_string(volumeCount) + ",\"version\":" + quote(readVersion) +
                ",\"editable\":" + (editable ? "true" : "false") + ",\"comment\":" + quote(archiveComment(reader)) + ",\"items\":" + items + "}");
        }
        if (op == "test") {
            reader.test();
            checkCancellation(job);
            if (volumeVersion(archive) != initialVolumes) throw std::runtime_error("测试期间压缩包或分卷已变化，请重新打开");
            return result("{\"ok\":true}");
        }
        const bool smart = op == "extractSmart" || op == "extractSmartFlat";
        const bool exporting = op == "export";
        if (exporting) {
            if (job->exportVersion.empty() || job->exportVersion != readVersion) throw std::runtime_error("拖出期间压缩包已变化，请重新打开后再操作");
            job->exportPath = logicalPath(job->exportPath);
            if (indexCount <= 0) throw std::runtime_error("拖出请求缺少选中项目");
            const auto items = reader.items();
            for (int index = 0; index < indexCount; ++index) {
                if (indices[index] >= items.size() || !selectedPath(logicalPath(items[indices[index]].path(), true), {job->exportPath})) {
                    throw std::runtime_error("拖出请求包含目标之外的项目");
                }
            }
        }
        if (op != "extract" && op != "extractHere" && op != "extractFlat" && op != "extractHereFlat" && !smart && !exporting) throw std::runtime_error("未知操作");
        if (job->extractionPolicy > 4) throw std::runtime_error("无效的解压同名处理方式");
        localfs::path target = localfs::absolute(destination);
        bool intoExisting = op == "extractHere" || op == "extractHereFlat";
        if (intoExisting && !localfs::is_directory(target)) throw std::runtime_error("目标文件夹不存在");
        if (!intoExisting && !smart && localfs::exists(target)) throw std::runtime_error("目标目录已存在，请选择新目录名");
        struct stat targetIdentity{}, parentIdentity{};
        bool targetWasDirectory = false;
        if (smart) {
            target = localfs::canonical(target.parent_path()) / target.filename();
            if (lstat(target.parent_path().c_str(), &parentIdentity) != 0) throw std::runtime_error("无法读取解压父目录状态");
            targetWasDirectory = lstat(target.c_str(), &targetIdentity) == 0 && S_ISDIR(targetIdentity.st_mode);
        } else if (intoExisting) {
            target = localfs::canonical(target);
            if (lstat(target.c_str(), &targetIdentity) != 0) throw std::runtime_error("无法读取解压目标目录状态");
        }
        StagingDirectory staging(intoExisting ? target : target.parent_path());
        ExtractionPermissions permissions;
        extractSafely(reader, staging.path, indices, indexCount, job, permissions);
        checkCancellation(job);
        if (volumeVersion(archive) != initialVolumes) throw std::runtime_error("解压期间压缩包或分卷已变化，请重新打开");
        const auto root = exporting ? staging.path / job->exportPath :
            extractionRoot(staging.path, op == "extractFlat" || op == "extractHereFlat" || op == "extractSmartFlat");
        if (exporting) {
            const auto type = localfs::symlink_status(root);
            if (localfs::is_symlink(type)) throw std::runtime_error("拖出符号链接时请选择包含其目标的目录");
            if (!localfs::is_directory(type) && !localfs::is_regular_file(type)) throw std::runtime_error("拖出项目未完整解压");
            if (localfs::is_directory(type)) normalizeExportLinks(root);
        }
        localfs::path outputRelative;
        if (smart) {
            auto entry = localfs::directory_iterator(root);
            if (entry != localfs::directory_iterator()) {
                const auto only = entry->path().filename();
                if (++entry == localfs::directory_iterator()) {
                    // 单文件或单目录直接落到所选父目录，避免再套一层同名目录。
                    outputRelative = only;
                    target = target.parent_path();
                    targetIdentity = parentIdentity;
                    intoExisting = true;
                }
            }
            if (outputRelative.empty()) intoExisting = targetWasDirectory;
        }
        auto resultPath = target;
        if (intoExisting) {
            const auto published = publishExtraction(root, target, job, staging, archive, targetIdentity, permissions, initialVolumes, outputRelative);
            if (!published.empty()) resultPath /= published;
        }
        else {
            if (localfs::is_directory(localfs::symlink_status(root))) validateMaterializedLinks(root);
            checkCancellation(job);
            if (volumeVersion(archive) != initialVolumes) throw std::runtime_error("发布期间压缩包或分卷已变化，请重新打开");
            struct stat published{};
            if (lstat(root.c_str(), &published) != 0) throw std::runtime_error("无法读取待发布的解压结果");
            publish(root, target);
            try {
                // 目录跨父级移动需要写权限，最终权限在发布完成后应用。
                permissions.apply();
                checkCancellation(job);
                if (volumeVersion(archive) != initialVolumes) throw std::runtime_error("发布期间压缩包或分卷已变化，请重新打开");
            } catch (...) {
                permissions.rollback();
                struct stat current{};
                if (lstat(target.c_str(), &current) != 0 || !sameExtractedFile(published, current, true) ||
                    renamex_np(target.c_str(), root.c_str(), RENAME_EXCL) != 0) {
                    staging.preserve = true;
                    throw std::runtime_error("目标被并发修改，解压结果保留于 " + target.string());
                }
                throw;
            }
            // 整个暂存目录已成为用户结果，清理职责随发布转移。
            if (root == staging.path) staging.preserve = true;
        }
        permissions.commit();
        return result("{\"ok\":true,\"version\":" + quote(readVersion) + ",\"path\":" + quote(resultPath.string()) + "}");
    } catch (const ExtractionConflict& conflict) {
        std::string paths = "[";
        for (const auto& path : conflict.paths) { if (paths.size() > 1) paths += ','; paths += quote(path); }
        return result("{\"ok\":false,\"error\":" + quote(conflict.what()) + ",\"destinationVersion\":" + quote(conflict.version) + ",\"conflicts\":" + paths + "]}");
    } catch (const BitException& error) {
        const bool passwordRequired = error.code() == BitFailureSource::WrongPassword;
        const auto message = job->limitExceeded.load() ? std::string("预览内容超过资源上限，请缩小选中范围或直接解压") :
            multiVolume && !passwordRequired ? std::string("分卷缺失、顺序错误或损坏。") + error.what() : error.what();
        return result("{\"ok\":false,\"cancelled\":" + std::string(job->cancelled ? "true" : "false") +
            ",\"passwordRequired\":" + (passwordRequired ? "true" : "false") + ",\"volumeError\":" + (multiVolume ? "true" : "false") + ",\"error\":" + quote(message) + "}");
    } catch (const std::exception& error) {
        return result("{\"ok\":false,\"cancelled\":" + std::string(job->cancelled ? "true" : "false") +
            ",\"volumeError\":" + (multiVolume ? "true" : "false") + ",\"error\":" + quote(error.what()) + "}");
    } catch (...) {
        return result("{\"ok\":false,\"error\":\"原生压缩引擎发生未知错误\"}");
    }
}
// 编辑副本后校验，再原子替换原包。版本标识和文件锁防止覆盖过期或并发修改。
static char* mutateArchive(
    Job* job, const char* engine, const char* archive, const char* actionValue, const char* itemPath,
    const char* editedFile, const char* password, const char* expectedVersion,
    const char* const* inputs, int inputCount) {
    try {
        checkCancellation(job);
        const auto target = localfs::canonical(archive);
        ArchiveLock lock(target.c_str());
        if (access(target.c_str(), W_OK) != 0) throw std::runtime_error("压缩包为只读，编辑文件已保留");
        const std::string expected(expectedVersion);
        if (expected.empty() || (archiveVersion(archive) != expected && volumeVersion(archive) != expected)) {
            throw std::runtime_error("原压缩包已被其他操作修改，已保留编辑文件，请重新核对后合并");
        }
        Bit7zLibrary library(engine);
        ZipEncodingScope encoding(engine, archive, job->codePage);
        const std::string action(actionValue);
        bool sevenZip = false;
        bool encrypted = false;
        std::vector<BitArchiveItemInfo> originalItems;
        std::map<std::string, std::string> originalMetadata;
        std::string encryptionMethod;
        {
            BitArchiveReader reader(library, archive, BitFormat::Auto, password);
            sevenZip = reader.detectedFormat() == BitFormat::SevenZip;
            if (reader.isMultiVolume()) throw std::runtime_error("分卷压缩包暂不支持包内修改，请先解压");
            if (!sevenZip && reader.detectedFormat() != BitFormat::Zip) {
                throw std::runtime_error("当前支持 ZIP 和 7z 的编辑回写");
            }
            int matches = 0;
            originalItems = reader.items();
            for (const auto& item : originalItems) {
                if (item.isSymLink() || !item.itemProperty(BitProperty::HardLink).isEmpty()) {
                    throw std::runtime_error("含链接的压缩包暂以只读方式打开，请先解压后重新打包");
                }
            }
            for (const auto& item : originalItems) {
                if (action == "update" && item.path() != itemPath) continue;
                ++matches;
                validateEntry(item);
                if (action == "update" && item.isDir()) throw std::runtime_error("请选择文件进行编辑");
                encrypted = encrypted || item.isEncrypted();
                const auto method = item.itemProperty(BitProperty::Method);
                if (item.isEncrypted() && method.isString()) encryptionMethod = method.getString();
            }
            if (action == "update" && matches != 1) throw std::runtime_error("压缩包内文件缺失或路径重复，已停止更新");
            callbacks(reader, job);
            originalMetadata = archiveMetadata(reader, job);
            reader.test();
        }
        if (encrypted && !password[0]) throw std::runtime_error("更新加密文件需要压缩包密码");
        bool cryptHeaders = false;
        if (sevenZip && password[0]) {
            try { BitArchiveReader probe(library, archive, BitFormat::Auto); }
            catch (const std::exception&) { cryptHeaders = true; }
        }
        StagingDirectory staging(target.parent_path());
        const auto modified = staging.path / (sevenZip ? "updated.7z" : "updated.zip");
        if (copyfile(target.c_str(), modified.c_str(), nullptr, COPYFILE_ALL | COPYFILE_EXCL) != 0) {
            throw std::runtime_error("无法创建压缩包更新副本，请检查权限与磁盘空间");
        }
        if (archiveVersion(archive) != expected) throw std::runtime_error("复制期间原压缩包发生变化，已停止更新");
        {
            BitArchiveEditor editor(library, modified.string(), sevenZip ? BitFormat::SevenZip : BitFormat::Zip, password);
            callbacks(editor, job);
            editor.setPassword(encrypted || cryptHeaders ? password : "", cryptHeaders);
            if (!sevenZip && encryptionMethod.find("AES-") != std::string::npos) {
                std::wstring method = L"AES256";
                if (encryptionMethod.find("AES-128") != std::string::npos) method = L"AES128";
                if (encryptionMethod.find("AES-192") != std::string::npos) method = L"AES192";
                editor.setFormatProperty(L"em", method);
            }
            applyArchiveMutation(editor, originalItems, action, itemPath, editedFile, inputs, inputCount, target, staging.path, job, originalMetadata);
            editor.applyChanges();
        }
        std::string items;
        std::string comment;
        {
            BitArchiveReader verified(library, modified.string(), BitFormat::Auto, password);
            callbacks(verified, job);
            verified.test();
            items = archiveItems(verified, job);
            comment = archiveComment(verified);
        }
        if (copyfile(target.c_str(), modified.c_str(), nullptr, COPYFILE_METADATA) != 0) {
            throw std::runtime_error("无法保留原压缩包文件属性，已停止更新");
        }
        const struct timespec times[2] = {{0, UTIME_OMIT}, {0, UTIME_NOW}};
        if (utimensat(AT_FDCWD, modified.c_str(), times, 0) != 0) throw std::runtime_error("无法更新压缩包修改时间");
        const int output = open(modified.c_str(), O_RDONLY);
        if (output < 0) throw std::runtime_error("无法打开更新副本进行保存校验");
        const int flushed = fsync(output);
        close(output);
        if (flushed != 0) throw std::runtime_error("压缩包更新副本未能完整保存");
        checkCancellation(job);
        if (archiveVersion(archive) != expected || archiveVersion(target.c_str()) != expected) {
            throw std::runtime_error("更新期间原压缩包发生变化，已保留编辑文件");
        }
        if (rename(modified.c_str(), target.c_str()) != 0) {
            throw std::runtime_error("无法替换原压缩包，已保留编辑文件");
        }
        return result("{\"ok\":true,\"editable\":true,\"version\":" + quote(archiveVersion(archive)) +
            ",\"comment\":" + quote(comment) + ",\"items\":" + items + "}");
    } catch (const MutationConflict& conflict) {
        std::string paths = "[";
        for (const auto& path : conflict.paths) { if (paths.size() > 1) paths += ','; paths += quote(path); }
        return result("{\"ok\":false,\"error\":" + quote(conflict.what()) + ",\"conflicts\":" + paths + "]}");
    } catch (const BitException& error) {
        const bool passwordRequired = error.code() == BitFailureSource::WrongPassword;
        return result("{\"ok\":false,\"cancelled\":" + std::string(job->cancelled ? "true" : "false") +
            ",\"passwordRequired\":" + (passwordRequired ? "true" : "false") + ",\"error\":" + quote(error.what()) + "}");
    } catch (const std::exception& error) {
        return result("{\"ok\":false,\"cancelled\":" + std::string(job->cancelled ? "true" : "false") +
            ",\"error\":" + quote(error.what()) + "}");
    } catch (...) {
        return result("{\"ok\":false,\"error\":\"压缩包更新失败，已保留编辑文件\"}");
    }
}

__attribute__((visibility("default"))) char* f7_update(
    Job* job, const char* engine, const char* archive, const char* itemPath,
    const char* editedFile, const char* password, const char* expectedVersion) {
    return mutateArchive(job, engine, archive, "update", itemPath, editedFile, password, expectedVersion, nullptr, 0);
}

__attribute__((visibility("default"))) char* f7_mutate(
    Job* job, const char* engine, const char* archive, const char* action, const char* itemPath,
    const char* destination, const char* password, const char* expectedVersion,
    const char* const* inputs, int inputCount) {
    return mutateArchive(job, engine, archive, action, itemPath, destination, password, expectedVersion, inputs, inputCount);
}

}
