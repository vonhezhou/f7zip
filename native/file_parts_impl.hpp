// 复用桥接层的 Job、暂存目录、来源版本和排他发布保护。
#pragma once
#include "file_parts_types.hpp"

class FilePartInput {
public:
    int descriptor = -1;
    struct stat status{};
    std::string version;
    explicit FilePartInput(const localfs::path& path) {
        descriptor = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
        if (descriptor < 0) throw std::runtime_error("无法读取普通文件或分片。" + path.string());
        struct stat entry{};
        if (fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode) ||
            lstat(path.c_str(), &entry) != 0 || entry.st_dev != status.st_dev || entry.st_ino != status.st_ino) {
            close(descriptor); descriptor = -1;
            throw std::runtime_error("来源必须为未变化的实际普通文件");
        }
        try { version = mutationSourceVersion(path); }
        catch (...) { close(descriptor); descriptor = -1; throw; }
    }
    ~FilePartInput() { if (descriptor >= 0) close(descriptor); }
    size_t read(char* buffer, size_t size) {
        ssize_t count;
        do { count = ::read(descriptor, buffer, size); } while (count < 0 && errno == EINTR);
        if (count < 0) throw std::runtime_error("读取文件或分片失败");
        return static_cast<size_t>(count);
    }
};

class FilePartOutput {
    int descriptor = -1;
public:
    FilePartOutput(const StagingDirectory& staging, const localfs::path& name) {
        descriptor = openat(staging.descriptor, name.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (descriptor < 0) throw std::runtime_error("无法创建暂存文件，请检查磁盘空间及权限");
    }
    ~FilePartOutput() { if (descriptor >= 0) close(descriptor); }
    void write(const char* buffer, size_t size) {
        while (size) {
            const auto count = ::write(descriptor, buffer, size);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) throw std::runtime_error("写入文件失败，请检查磁盘空间");
            buffer += count;
            size -= static_cast<size_t>(count);
        }
    }
    void attributes(const FilePartsInfo& info) {
        const struct timespec times[2] = {{0, UTIME_OMIT}, {info.modified, static_cast<long>(info.modifiedNanoseconds)}};
        if (fchmod(descriptor, info.permissions) != 0 || futimens(descriptor, times) != 0) {
            throw std::runtime_error("无法恢复合并文件的权限及修改时间");
        }
    }
    void finish() {
        if (fsync(descriptor) != 0) throw std::runtime_error("文件未能完整保存");
        const int status = close(descriptor);
        descriptor = -1;
        if (status != 0) throw std::runtime_error("无法完成文件写入");
    }
};

static std::string filePartName(const std::string& prefix, size_t index) {
    std::ostringstream name;
    name << prefix << '.' << std::setw(3) << std::setfill('0') << index + 1;
    return name.str();
}

static std::string filePartKey(const std::string& name) {
    auto key = normalizeUnicodeName(name, 1);
    std::transform(key.begin(), key.end(), key.begin(), [](unsigned char byte) { return byte >= 'A' && byte <= 'Z' ? byte + ('a' - 'A') : byte; });
    return key;
}

static std::string filePartsJson(const FilePartsInfo& info) {
    std::string json = "{\"format\":\"F7ZipFileParts\",\"version\":1,\"name\":" + quote(info.name) +
        ",\"prefix\":" + quote(info.prefix) + ",\"size\":" + std::to_string(info.size) +
        ",\"partSize\":" + std::to_string(info.partSize) + ",\"sha256\":" + quote(info.sha256) +
        ",\"permissions\":" + std::to_string(info.permissions) + ",\"modified\":" + std::to_string(info.modified) +
        ",\"modifiedNanoseconds\":" + std::to_string(info.modifiedNanoseconds) + ",\"parts\":[";
    for (size_t index = 0; index < info.parts.size(); ++index) {
        if (index) json += ',';
        const auto& part = info.parts[index];
        json += "{\"name\":" + quote(part.name) + ",\"size\":" + std::to_string(part.size) + ",\"sha256\":" + quote(part.sha256) + '}';
    }
    json += "]}";
    if (json.size() > 4 * 1024 * 1024) throw std::runtime_error("分片清单超过 4 MiB，请缩短输出名称或减少分片数量");
    return json;
}

static std::string filePartsSummary(const FilePartsInfo& info, const localfs::path& manifest,
    const std::string& version, const localfs::path& output = {}) {
    return "{\"ok\":true,\"name\":" + quote(info.name) + ",\"count\":" + std::to_string(info.parts.size()) +
        ",\"size\":" + std::to_string(info.size) + ",\"sha256\":" + quote(info.sha256) +
        ",\"manifest\":" + quote(manifest.string()) + ",\"version\":" + quote(version) +
        ",\"path\":" + quote((output.empty() ? manifest : output).string()) + '}';
}

static localfs::path filePartsManifestPath(const char* source) {
    const auto selected = localfs::absolute(source).lexically_normal();
    const auto name = selected.filename().string();
    const auto key = filePartKey(name);
    const std::string suffix = ".f7zip-parts.json";
    if (key.size() >= suffix.size() && key.compare(key.size() - suffix.size(), suffix.size(), suffix) == 0) return selected;
    if (key.size() > 4 && key.compare(key.size() - 4, 4, ".001") == 0) {
        return selected.parent_path() / (name.substr(0, name.size() - 4) + suffix);
    }
    throw std::runtime_error("请选择 .001 首片或 F7Zip 分片清单");
}

static void validateFileParts(const FilePartsInfo& info, const localfs::path& directory,
    std::map<std::string, std::string>& versions, Job* job) {
    std::set<std::string> expected;
    for (const auto& part : info.parts) {
        checkCancellation(job);
        const auto path = directory / part.name;
        expected.insert(filePartKey(part.name));
        if (localfs::symlink_status(path).type() == localfs::file_type::not_found) {
            throw std::runtime_error("缺少分片。" + part.name);
        }
        FilePartInput input(path);
        if (static_cast<uint64_t>(input.status.st_size) != part.size) throw std::runtime_error("分片大小错误。" + part.name);
        versions.emplace(path.string(), input.version);
    }
    const auto family = volumeFamily(info.prefix + ".001");
    for (const auto& entry : localfs::directory_iterator(directory)) {
        checkCancellation(job);
        const auto name = entry.path().filename().string();
        if (volumeFamily(name) == family && !expected.count(filePartKey(name))) {
            throw std::runtime_error("分片组包含清单以外的分片，请先核对。" + name);
        }
    }
}

static FilePartsInfo loadFileParts(const localfs::path& manifest,
    std::map<std::string, std::string>& versions, Job* job) {
    if (localfs::symlink_status(manifest).type() == localfs::file_type::not_found) {
        throw std::runtime_error("缺少 F7Zip 分片清单，请保留完整分片和清单。" + manifest.string());
    }
    FilePartInput input(manifest);
    if (input.status.st_size > 4 * 1024 * 1024) throw std::runtime_error("分片清单超过 4 MiB");
    std::string json(static_cast<size_t>(input.status.st_size), '\0');
    size_t offset = 0;
    while (offset < json.size()) {
        checkCancellation(job);
        const auto count = input.read(json.data() + offset, json.size() - offset);
        if (!count) throw std::runtime_error("分片清单读取不完整");
        offset += count;
    }
    versions.emplace(manifest.string(), input.version);
    if (!job->exportVersion.empty() && job->exportVersion != input.version) throw std::runtime_error("选择输出期间分片清单已变化，请重新选择");
    const auto info = parseFilePartsManifest(json);
    if (filePartKey(manifest.filename().string()) != filePartKey(info.prefix + ".f7zip-parts.json")) {
        throw std::runtime_error("清单名称与分片组不一致，请保留原有分片组名称");
    }
    validateFileParts(info, manifest.parent_path(), versions, job);
    validateMutationSources(versions, job);
    return info;
}

static std::string splitPlainFile(Job* job, const char* sourceValue, const char* destination) {
    if (!job->volumeSize || job->volumeSize > 2097151ULL * 1048576) throw std::runtime_error("无效的分片大小");
    const auto source = localfs::absolute(sourceValue).lexically_normal();
    FilePartInput input(source);
    FilePartsInfo info;
    info.name = source.filename().string();
    info.size = static_cast<uint64_t>(input.status.st_size);
    info.partSize = job->volumeSize;
    info.permissions = input.status.st_mode & 0777;
    info.modified = input.status.st_mtimespec.tv_sec;
    info.modifiedNanoseconds = input.status.st_mtimespec.tv_nsec;
    const uint64_t count = std::max<uint64_t>(1, info.size / info.partSize + (info.size % info.partSize != 0));
    if (count > 10000) throw std::runtime_error("分片超过 10000 片，请增大每片大小");
    const auto requested = localfs::absolute(destination).lexically_normal();
    const auto target = localfs::canonical(requested.parent_path()) / requested.filename();
    info.prefix = target.filename().string();
    const auto manifest = target.parent_path() / (info.prefix + ".f7zip-parts.json");
    checkOutputGroup(target);
    if (localfs::symlink_status(manifest).type() != localfs::file_type::not_found) throw std::runtime_error("分片清单已存在，请使用新的输出名称");
    struct stat targetIdentity{};
    if (lstat(target.parent_path().c_str(), &targetIdentity) != 0 || !S_ISDIR(targetIdentity.st_mode)) throw std::runtime_error("输出目录不可用，请选择实际目录");
    const std::map<std::string, std::string> versions = {{source.string(), input.version}};
    const auto sourceVolumes = volumeVersion(source.c_str());
    StagingDirectory staging(target.parent_path());
    std::vector<char> buffer(1024 * 1024);
    CC_SHA256_CTX fullHash;
    CC_SHA256_Init(&fullHash);
    job->total = info.size;
    uint64_t remaining = info.size;
    for (size_t index = 0; index < count; ++index) {
        checkCancellation(job);
        FilePartInfo part;
        part.name = filePartName(info.prefix, index);
        part.size = std::min(info.partSize, remaining);
        {
            std::lock_guard<std::mutex> guard(job->mutex);
            job->currentFile = part.name;
        }
        FilePartOutput output(staging, part.name);
        CC_SHA256_CTX partHash;
        CC_SHA256_Init(&partHash);
        uint64_t left = part.size;
        while (left) {
            checkCancellation(job);
            const auto size = input.read(buffer.data(), static_cast<size_t>(std::min<uint64_t>(buffer.size(), left)));
            if (!size) throw std::runtime_error("来源文件已变短，已停止分割");
            output.write(buffer.data(), size);
            CC_SHA256_Update(&partHash, buffer.data(), static_cast<CC_LONG>(size));
            CC_SHA256_Update(&fullHash, buffer.data(), static_cast<CC_LONG>(size));
            left -= size;
            job->completed += size;
        }
        output.finish();
        part.sha256 = finishSha256(partHash);
        remaining -= part.size;
        info.parts.push_back(std::move(part));
    }
    info.sha256 = finishSha256(fullHash);
    validateMutationSources(versions, job);
    const auto json = filePartsJson(info);
    FilePartOutput metadata(staging, manifest.filename());
    metadata.write(json.data(), json.size());
    metadata.finish();
    checkOutputGroup(target);
    validateMutationSources(versions, job);
    ExtractionPermissions permissions;
    struct stat stagedIdentity{};
    if (fstat(staging.descriptor, &stagedIdentity) != 0) throw std::runtime_error("无法验证暂存目录");
    publishExtraction(staging.currentPath(), target.parent_path(), job, staging, source, targetIdentity, permissions, sourceVolumes, {}, &stagedIdentity);
    if (!localfs::is_regular_file(manifest)) {
        staging.preserve = true;
        throw std::runtime_error("分片发布后清单不可用，请核对输出目录与暂存结果。" + staging.currentPath().string());
    }
    permissions.commit();
    return filePartsSummary(info, manifest, mutationSourceVersion(manifest), target.parent_path() / info.parts.front().name);
}

static std::string joinPlainFile(Job* job, const char* sourceValue, const char* destination, bool infoOnly) {
    const auto manifest = filePartsManifestPath(sourceValue);
    std::map<std::string, std::string> versions;
    const auto info = loadFileParts(manifest, versions, job);
    if (infoOnly) return filePartsSummary(info, manifest, versions.at(manifest.string()));
    const auto requested = localfs::absolute(destination).lexically_normal();
    const auto target = localfs::canonical(requested.parent_path()) / requested.filename();
    if (localfs::symlink_status(target).type() != localfs::file_type::not_found) throw std::runtime_error("合并目标已存在，请使用新文件名");
    struct stat targetIdentity{};
    if (lstat(target.parent_path().c_str(), &targetIdentity) != 0 || !S_ISDIR(targetIdentity.st_mode)) throw std::runtime_error("输出目录不可用，请选择实际目录");
    const auto first = manifest.parent_path() / info.parts.front().name;
    const auto sourceVolumes = volumeVersion(first.c_str());
    StagingDirectory staging(target.parent_path());
    FilePartOutput output(staging, target.filename());
    CC_SHA256_CTX fullHash;
    CC_SHA256_Init(&fullHash);
    std::vector<char> buffer(1024 * 1024);
    job->total = info.size;
    for (const auto& part : info.parts) {
        checkCancellation(job);
        {
            std::lock_guard<std::mutex> guard(job->mutex);
            job->currentFile = part.name;
        }
        const auto path = manifest.parent_path() / part.name;
        FilePartInput input(path);
        if (input.version != versions.at(path.string())) throw std::runtime_error("合并期间分片已变化");
        CC_SHA256_CTX partHash;
        CC_SHA256_Init(&partHash);
        uint64_t left = part.size;
        while (left) {
            checkCancellation(job);
            const auto count = input.read(buffer.data(), static_cast<size_t>(std::min<uint64_t>(buffer.size(), left)));
            if (!count) throw std::runtime_error("分片读取不完整。" + part.name);
            output.write(buffer.data(), count);
            CC_SHA256_Update(&partHash, buffer.data(), static_cast<CC_LONG>(count));
            CC_SHA256_Update(&fullHash, buffer.data(), static_cast<CC_LONG>(count));
            left -= count;
            job->completed += count;
        }
        if (finishSha256(partHash) != part.sha256) throw std::runtime_error("分片 SHA-256 不一致，请核对顺序及内容。" + part.name);
    }
    if (finishSha256(fullHash) != info.sha256) throw std::runtime_error("合并结果 SHA-256 与原文件不一致");
    output.attributes(info);
    output.finish();
    validateMutationSources(versions, job);
    ExtractionPermissions permissions;
    struct stat stagedIdentity{};
    if (fstat(staging.descriptor, &stagedIdentity) != 0) throw std::runtime_error("无法验证暂存目录");
    publishExtraction(staging.currentPath(), target.parent_path(), job, staging, first, targetIdentity, permissions, sourceVolumes, {}, &stagedIdentity);
    permissions.commit();
    return filePartsSummary(info, manifest, versions.at(manifest.string()), target);
}
