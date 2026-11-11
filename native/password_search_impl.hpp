#pragma once

static std::string passwordSearch(Job* job, const Bit7zLibrary& library, const char* engine,
    const char* archive, const char* const* candidates, int count, bool infoOnly) {
    FilePartInput input(localfs::absolute(archive));
    if (input.status.st_size > 512LL * 1048576) throw std::runtime_error("密码恢复当前支持不超过 512 MiB 的单卷 ZIP / 7z");
    if (input.status.st_size < 6) throw std::runtime_error("归档过短，无法进行密码恢复");
    std::string signature(6, '\0');
    if (input.read(signature.data(), signature.size()) != signature.size()) throw std::runtime_error("无法读取归档标记");
    const bool zip = signature.compare(0, 4, "PK\x03\x04") == 0;
    const bool seven = signature == std::string("7z\xbc\xaf\x27\x1c", 6);
    if (!zip && !seven) throw std::runtime_error("密码恢复当前支持独立 ZIP / 7z，不支持分卷或自解压包");
    const auto volumes = volumeVersion(archive);
    const std::map<std::string, std::string> versions = {{localfs::absolute(archive).string(), input.version}};
    if (!job->exportVersion.empty() && job->exportVersion != volumes) throw std::runtime_error("归档已变化，请重新配置密码恢复");
    if (infoOnly) return "{\"ok\":true,\"version\":" + quote(volumes) + '}';
    if (job->exportVersion.empty() || count < 1 || count > 8 || !candidates) throw std::runtime_error("密码恢复需要源版本和每批 1–8 个候选");
    ZipEncodingScope encoding(engine, archive, job->codePage);
    job->total = static_cast<uint64_t>(count);
    for (int index = 0; index < count; ++index) {
        checkCancellation(job);
        if (!candidates[index] || strlen(candidates[index]) > 4096) throw std::runtime_error("密码候选超过 4096 字节");
        validateMutationSources(versions, job);
        bool matched = false;
        try {
            BitArchiveReader reader(library, archive, zip ? BitFormat::Zip : BitFormat::SevenZip, candidates[index]);
            if (reader.isMultiVolume()) throw std::runtime_error("密码恢复暂不支持分卷归档");
            const auto items = reader.items();
            if (items.size() > 10000) throw std::runtime_error("密码恢复当前支持最多 10000 个归档条目");
            const BitArchiveItemInfo* selected = nullptr;
            uint64_t total = 0;
            for (const auto& item : items) {
                if (item.size() > 256ULL * 1048576 - total) throw std::runtime_error("密码恢复的归档总展开大小上限为 256 MiB");
                total += item.size();
                if (!item.isDir() && item.isEncrypted() && (!selected || item.size() < selected->size())) selected = &item;
            }
            if (!selected) throw std::runtime_error("没有可验证的加密文件条目");
            if (selected->size() > 64ULL * 1048576) throw std::runtime_error("最小加密条目超过 64 MiB，已停止密码恢复");
            // 候选数进度独立于解码字节，取消和展开预算仍在引擎回调中生效。
            reader.setProgressCallback([job](uint64_t completed) {
                if (completed > 256ULL * 1048576) job->limitExceeded = true;
                return !job->cancelled && !job->limitExceeded;
            });
            reader.testItem(selected->index());
            matched = true;
        } catch (const BitException& error) {
            checkCancellation(job);
            if (job->limitExceeded) throw std::runtime_error("密码验证超过展开资源上限");
            if (error.code() != BitFailureSource::WrongPassword &&
                error.code() != BitFailureSource::CRCError && error.code() != BitFailureSource::DataError) throw;
        }
        checkCancellation(job);
        validateMutationSources(versions, job);
        if (volumeVersion(archive) != volumes) throw std::runtime_error("搜索期间归档或分卷已变化，请重新开始");
        job->completed = index + 1;
        if (matched) return "{\"ok\":true,\"found\":" + std::to_string(index) + ",\"tested\":" + std::to_string(index + 1) + '}';
    }
    return "{\"ok\":true,\"found\":-1,\"tested\":" + std::to_string(count) + '}';
}
