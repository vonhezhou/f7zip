#include "zip_encoding.hpp"
#include <bit7z/bit7zlibrary.hpp>
#include <bit7z/bitarchivereader.hpp>
#include <bit7z/bitfilecompressor.hpp>
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
#include <copyfile.h>
#include <map>
#include <set>
#include <iomanip>

namespace localfs = std::filesystem;
using namespace bit7z;

struct Job {
    uint32_t codePage = 0;
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

static void callbacks(BitAbstractArchiveHandler& handler, Job* job) {
    handler.setTotalCallback([job](uint64_t total) { job->total = total; });
    handler.setProgressCallback([job](uint64_t value) {
        job->completed = value;
        return !job->cancelled.load();
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
    explicit StagingDirectory(const localfs::path& parent) {
        auto pattern = (parent / ".f7zip-XXXXXX").string();
        std::vector<char> buffer(pattern.begin(), pattern.end());
        buffer.push_back(0);
        char* created = mkdtemp(buffer.data());
        if (!created) throw std::runtime_error("无法创建临时目录，请检查目标目录权限与磁盘空间");
        path = created;
    }
    ~StagingDirectory() {
        std::error_code ignored;
        localfs::remove_all(path, ignored);
    }
};

static void publish(const localfs::path& source, const localfs::path& target) {
    // RENAME_EXCL 保证并发任务也不会覆盖已存在的文件或目录。
    if (renamex_np(source.c_str(), target.c_str(), RENAME_EXCL) != 0) {
        throw std::runtime_error(std::string("无法保存结果，目标可能已存在或不可写。") + strerror(errno));
    }
}

// 先检查全部顶层条目，再逐个排他发布。发布失败时将本次结果移回暂存目录。
static void publishContents(const localfs::path& staging, const localfs::path& target) {
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
            publish(staging / name, target / name);
            ++published;
        }
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

// 仅去掉一个独占的顶层目录，内部目录结构保持完整，空目录也可直接发布。
static localfs::path extractionRoot(const localfs::path& staging, bool removeRedundantRoot) {
    if (!removeRedundantRoot) return staging;
    auto entry = localfs::directory_iterator(staging);
    if (entry == localfs::directory_iterator()) return staging;
    const auto root = entry->path();
    if (!localfs::is_directory(localfs::symlink_status(root))) return staging;
    if (++entry != localfs::directory_iterator()) return staging;
    return root;
}

static void validateEntry(const BitArchiveItemInfo& item) {
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
    if (item.isSymLink() || !item.itemProperty(BitProperty::HardLink).isEmpty()) {
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
        if (descriptor < 0) throw std::runtime_error("无法打开待更新压缩包");
        if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
            close(descriptor);
            throw std::runtime_error("其他任务正在更新此压缩包，请稍后重试");
        }
    }
    ~ArchiveLock() { flock(descriptor, LOCK_UN); close(descriptor); }
};

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

class MutationConflict : public std::runtime_error {
public:
    std::vector<std::string> paths;
    explicit MutationConflict(std::vector<std::string> values)
        : std::runtime_error("添加的文件与压缩包内文件重名"), paths(std::move(values)) {}
};

static void applyArchiveMutation(BitArchiveEditor& editor, const std::vector<BitArchiveItemInfo>& items,
    const std::string& action, const char* itemPath, const char* destination,
    const char* const* inputs, int inputCount, const localfs::path& archive, const localfs::path& staging, Job* job) {
    if (action == "update") {
        editor.updateItem(std::string(itemPath), std::string(destination));
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
            if (selectedPath(name, selected)) { editor.deleteItem(item->index()); ++count; }
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
            if (name == from || name.compare(0, from.size() + 1, from + "/") == 0) {
                editor.renameItem(item->index(), to + name.substr(from.size())); ++count;
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

__attribute__((visibility("default"))) void f7_free(char* value) { free(value); }

__attribute__((visibility("default"))) char* f7_job_progress(Job* job) {
    std::lock_guard<std::mutex> guard(job->mutex);
    return result("{\"total\":" + std::to_string(job->total.load()) +
        ",\"completed\":" + std::to_string(job->completed.load()) +
        ",\"file\":" + quote(job->currentFile) + "}");
}

// operation 为 list / extract / extractHere / extractFlat / extractHereFlat / test / compress，所有字符串使用 UTF-8。
__attribute__((visibility("default"))) char* f7_run(
    Job* job, const char* engine, const char* operation, const char* archive,
    const char* destination, const char* password, const char* format, int level,
    const char* const* inputs, int inputCount, const uint32_t* indices, int indexCount) {
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
            const bool tarStream = std::string(format).rfind("tar.", 0) == 0;
            const bool singleFile = !tarStream && !outputFormat.hasFeature(FormatFeatures::MultipleFiles);
            if (singleFile && inputCount != 1) throw std::runtime_error("所选格式仅支持压缩一个普通文件");
            if (password[0] && !outputFormat.hasFeature(FormatFeatures::Encryption)) {
                throw std::runtime_error("所选格式不支持密码加密");
            }
            std::vector<std::string> paths;
            for (int i = 0; i < inputCount; ++i) {
                localfs::path source = localfs::canonical(inputs[i]);
                if (singleFile && !localfs::is_regular_file(source)) {
                    throw std::runtime_error("所选格式仅支持压缩一个普通文件");
                }
                if (localfs::is_directory(source)) {
                    auto relative = localfs::weakly_canonical(target).lexically_relative(source);
                    if (!relative.empty() && *relative.begin() != "..") {
                        throw std::runtime_error("请将压缩包保存到所选文件夹外，避免递归压缩自身");
                    }
                }
                paths.push_back(source.string());
            }
            StagingDirectory staging(target.parent_path());
            const bool sevenZip = outputFormat == BitFormat::SevenZip;
            BitFileCompressor compressor(library, outputFormat);
            callbacks(compressor, job);
            compressor.setCompressionLevel(static_cast<BitCompressionLevel>(level));
            if (password[0]) compressor.setPassword(password, sevenZip && std::string(format) != "7z-visible");
            if (std::string(format) == "zip-aes256") compressor.setFormatProperty(L"em", L"AES256");
            const auto output = staging.path / (std::string("archive.") + (tarStream ? "tar." : "") + outputFormat.extension());
            if (tarStream) {
                const auto tar = staging.path / "archive.tar";
                BitFileCompressor packer(library, BitFormat::Tar);
                callbacks(packer, job);
                packer.compress(paths, tar.string());
                checkCancellation(job);
                paths = {tar.string()};
            }
            compressor.compress(paths, output.string());
            checkCancellation(job);
            publish(output, target);
            return result("{\"ok\":true,\"path\":" + quote(target.string()) + "}");
        }
        const auto initialVersion = archiveVersion(archive);
        ZipEncodingScope encoding(engine, archive, job->codePage);
        // 复合归档的索引始终指向内层 TAR，浏览、选中解压与完整性测试共用同一入口。
        std::unique_ptr<StagingDirectory> intermediate;
        auto opened = std::make_unique<BitArchiveReader>(library, archive, BitFormat::Auto, password);
        callbacks(*opened, job);
        std::string archiveName = localfs::path(archive).filename().string();
        std::transform(archiveName.begin(), archiveName.end(), archiveName.begin(),
            [](unsigned char value) { return static_cast<char>(std::tolower(value)); });
        const std::vector<std::string> tarSuffixes = {".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz"};
        const bool namedTar = std::any_of(tarSuffixes.begin(), tarSuffixes.end(), [&](const auto& suffix) {
            return archiveName.size() >= suffix.size() && archiveName.compare(archiveName.size() - suffix.size(), suffix.size(), suffix) == 0;
        });
        const auto& outerFormat = opened->detectedFormat();
        if (namedTar && (outerFormat == BitFormat::GZip || outerFormat == BitFormat::BZip2 || outerFormat == BitFormat::Xz)) {
            for (const auto& item : opened->items()) validateEntry(item);
            intermediate = std::make_unique<StagingDirectory>(localfs::temp_directory_path());
            opened->extractTo(intermediate->path.string());
            checkCancellation(job);
            auto contents = localfs::directory_iterator(intermediate->path);
            if (contents == localfs::directory_iterator()) throw std::runtime_error("复合归档缺少内层 TAR");
            const auto tar = contents->path();
            if (!localfs::is_regular_file(localfs::symlink_status(tar)) || ++contents != localfs::directory_iterator()) {
                throw std::runtime_error("复合归档的内层 TAR 无效");
            }
            opened = std::make_unique<BitArchiveReader>(library, tar.string(), BitFormat::Tar, password);
            callbacks(*opened, job);
        }
        auto& reader = *opened;
        if (op == "list") {
            auto items = archiveItems(reader, job);
            if (archiveVersion(archive) != initialVersion) throw std::runtime_error("读取期间压缩包已变化，请重新打开");
            const bool editable = reader.detectedFormat() == BitFormat::Zip || reader.detectedFormat() == BitFormat::SevenZip;
            return result("{\"ok\":true,\"codePage\":" + std::to_string(encoding.codePage()) + ",\"version\":" + quote(initialVersion) +
                ",\"editable\":" + (editable ? "true" : "false") + ",\"comment\":" + quote(archiveComment(reader)) + ",\"items\":" + items + "}");
        }
        if (op == "test") {
            reader.test();
            checkCancellation(job);
            return result("{\"ok\":true}");
        }
        if (op != "extract" && op != "extractHere" && op != "extractFlat" && op != "extractHereFlat") throw std::runtime_error("未知操作");
        for (const auto& item : reader.items()) validateEntry(item);
        localfs::path target(destination);
        const bool intoExisting = op == "extractHere" || op == "extractHereFlat";
        if (intoExisting && !localfs::is_directory(target)) throw std::runtime_error("目标文件夹不存在");
        if (!intoExisting && localfs::exists(target)) throw std::runtime_error("目标目录已存在，请选择新目录名");
        StagingDirectory staging(intoExisting ? target : target.parent_path());
        if (indexCount > 0) {
            std::vector<uint32_t> selected(indices, indices + indexCount);
            std::sort(selected.begin(), selected.end());
            reader.extractTo(staging.path.string(), selected);
        } else {
            reader.extractTo(staging.path.string());
        }
        checkCancellation(job);
        if (archiveVersion(archive) != initialVersion) throw std::runtime_error("解压期间压缩包已变化，请重新打开");
        const auto root = extractionRoot(staging.path, op == "extractFlat" || op == "extractHereFlat");
        if (intoExisting) publishContents(root, target);
        else publish(root, target);
        return result("{\"ok\":true,\"version\":" + quote(initialVersion) + ",\"path\":" + quote(target.string()) + "}");
    } catch (const BitException& error) {
        const bool passwordRequired = error.code() == BitFailureSource::WrongPassword;
        return result("{\"ok\":false,\"cancelled\":" + std::string(job->cancelled ? "true" : "false") +
            ",\"passwordRequired\":" + (passwordRequired ? "true" : "false") + ",\"error\":" + quote(error.what()) + "}");
    } catch (const std::exception& error) {
        return result("{\"ok\":false,\"cancelled\":" + std::string(job->cancelled ? "true" : "false") +
            ",\"error\":" + quote(error.what()) + "}");
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
        if (expected.empty() || archiveVersion(archive) != expected) {
            throw std::runtime_error("原压缩包已被其他操作修改，已保留编辑文件，请重新核对后合并");
        }
        Bit7zLibrary library(engine);
        ZipEncodingScope encoding(engine, archive, job->codePage);
        const std::string action(actionValue);
        bool sevenZip = false;
        bool encrypted = false;
        std::vector<BitArchiveItemInfo> originalItems;
        std::string encryptionMethod;
        {
            BitArchiveReader reader(library, archive, BitFormat::Auto, password);
            sevenZip = reader.detectedFormat() == BitFormat::SevenZip;
            if (!sevenZip && reader.detectedFormat() != BitFormat::Zip) {
                throw std::runtime_error("当前支持 ZIP 和 7z 的编辑回写");
            }
            int matches = 0;
            originalItems = reader.items();
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
            applyArchiveMutation(editor, originalItems, action, itemPath, editedFile, inputs, inputCount, target, staging.path, job);
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
