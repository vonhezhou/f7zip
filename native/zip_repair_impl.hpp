#pragma once

// 从经典 ZIP 本地文件头重建目录，压缩数据保持原样，每个候选先交由引擎验证。
static uint16_t repairU16(const std::string& bytes, size_t offset) {
    return static_cast<unsigned char>(bytes[offset]) | (static_cast<unsigned char>(bytes[offset + 1]) << 8);
}

static uint32_t repairU32(const std::string& bytes, size_t offset) {
    return repairU16(bytes, offset) | (static_cast<uint32_t>(repairU16(bytes, offset + 2)) << 16);
}

static void repairInteger(std::string& bytes, uint32_t value, size_t count) {
    for (size_t index = 0; index < count; ++index) bytes.push_back(static_cast<char>(value >> (index * 8)));
}

class RepairReadFailure : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

static std::string repairRead(FilePartInput& input, uint64_t offset, size_t size, Job* job) {
    std::string bytes(size, '\0');
    size_t done = 0;
    while (done < size) {
        checkCancellation(job);
        const auto count = pread(input.descriptor, bytes.data() + done, size - done, static_cast<off_t>(offset + done));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) throw RepairReadFailure("ZIP 扫描期间来源已变化或读取不完整");
        done += static_cast<size_t>(count);
    }
    return bytes;
}

struct RepairMarker {
    uint64_t offset;
    uint16_t signature;
};

static std::vector<RepairMarker> repairMarkers(FilePartInput& input, Job* job) {
    std::vector<RepairMarker> markers;
    const auto size = static_cast<uint64_t>(input.status.st_size);
    job->total = size;
    for (uint64_t offset = 0; offset + 4 <= size;) {
        const auto bytes = repairRead(input, offset, static_cast<size_t>(std::min<uint64_t>(1048576, size - offset)), job);
        for (size_t index = 0; index + 4 <= bytes.size(); ++index) {
            if (bytes[index] != 'P' || bytes[index + 1] != 'K') continue;
            const auto signature = repairU16(bytes, index + 2);
            if (signature != 0x0403 && signature != 0x0201 && signature != 0x0605 && signature != 0x0807) continue;
            markers.push_back({offset + index, signature});
            if (markers.size() > 100000) throw std::runtime_error("ZIP 扫描候选超过 100000 个，请缩小输入范围");
        }
        if (bytes.size() <= 3) break;
        offset += bytes.size() - 3;
        job->completed = offset;
    }
    markers.push_back({size, 0});
    return markers;
}

static std::string repairCentral(const std::string& header, uint32_t crc, uint32_t packed,
    uint32_t unpacked, uint32_t offset) {
    std::string central;
    repairInteger(central, 0x02014b50, 4);
    repairInteger(central, 20, 2); // 仅恢复本地头可证明的字段，不推断原 Unix 属性。
    central.append(header, 4, 10);
    repairInteger(central, crc, 4);
    repairInteger(central, packed, 4);
    repairInteger(central, unpacked, 4);
    central.append(header, 26, 4);
    central.append(8, '\0'); // 注释长度、卷号、内部及外部属性。
    central.append(2, '\0');
    repairInteger(central, offset, 4);
    central.append(header, 30, std::string::npos);
    return central;
}

static std::string repairEnd(uint32_t count, uint32_t directorySize, uint32_t offset) {
    std::string end;
    repairInteger(end, 0x06054b50, 4);
    end.append(4, '\0');
    repairInteger(end, count, 2);
    repairInteger(end, count, 2);
    repairInteger(end, directorySize, 4);
    repairInteger(end, offset, 4);
    end.append(2, '\0');
    return end;
}

static void repairCopy(FilePartInput& input, uint64_t offset, uint64_t size, FilePartOutput& output, Job* job) {
    while (size) {
        const auto bytes = repairRead(input, offset, static_cast<size_t>(std::min<uint64_t>(1048576, size)), job);
        output.write(bytes.data(), bytes.size());
        offset += bytes.size();
        size -= bytes.size();
    }
}

static std::string repairZip(Job* job, const Bit7zLibrary& library, const char* engine,
    const char* sourceValue, const char* destination, const char* password) {
    const auto source = localfs::absolute(sourceValue).lexically_normal();
    FilePartInput input(source);
    if (input.status.st_size > UINT32_MAX) throw std::runtime_error("ZIP 修复当前支持小于 4 GiB 的经典单卷 ZIP");
    if (!job->exportVersion.empty() && job->exportVersion != input.version) throw std::runtime_error("选择输出期间源 ZIP 已变化");
    const auto requested = localfs::absolute(destination).lexically_normal();
    const auto target = localfs::canonical(requested.parent_path()) / requested.filename();
    if (localfs::symlink_status(target).type() != localfs::file_type::not_found) throw std::runtime_error("修复目标已存在，请选择新文件名");
    struct stat targetIdentity{};
    if (lstat(target.parent_path().c_str(), &targetIdentity) != 0) throw std::runtime_error("无法读取输出目录");
    const std::map<std::string, std::string> versions = {{source.string(), input.version}};
    const auto sourceVolumes = volumeVersion(source.c_str());
    StagingDirectory staging(target.parent_path()), workspace(target.parent_path());
    FilePartOutput output(staging, target.filename());
    const auto markers = repairMarkers(input, job);
    std::string directory, skipped = "[";
    uint64_t consumed = 0, outputSize = 0, unpackedTotal = 0;
    uint32_t recovered = 0, rejected = 0;
    std::map<std::string, bool> names;
    std::map<std::string, std::string> unicodePaths;
    for (size_t index = 0; index + 1 < markers.size(); ++index) {
        checkCancellation(job);
        const auto start = markers[index].offset;
        if (markers[index].signature != 0x0403 || start < consumed) continue;
        std::string label = "offset " + std::to_string(start);
        std::string header;
        uint32_t crc = 0, packed = 0, unpacked = 0;
        uint64_t recordSize = 0;
        bool checking = true;
        try {
            if (start + 30 > static_cast<uint64_t>(input.status.st_size)) throw std::runtime_error("本地文件头被截断");
            header = repairRead(input, start, 30, job);
            const uint64_t headerSize = 30 + repairU16(header, 26) + repairU16(header, 28);
            if (start + headerSize > static_cast<uint64_t>(input.status.st_size)) throw std::runtime_error("本地文件名或扩展字段被截断");
            header = repairRead(input, start, static_cast<size_t>(headerSize), job);
            crc = repairU32(header, 14);
            packed = repairU32(header, 18);
            unpacked = repairU32(header, 22);
            recordSize = headerSize + packed;
            if (packed == UINT32_MAX || unpacked == UINT32_MAX) throw std::runtime_error("ZIP64 条目暂不支持修复");
            if (repairU16(header, 6) & 8) {
                bool found = false;
                // 有签名的描述符可越过压缩数据中的伪 PK，未签名描述符需吻合后续边界。
                for (size_t next = index + 1; next < std::min(markers.size(), index + 4097); ++next) {
                    const auto marker = markers[next];
                    const bool signedDescriptor = marker.signature == 0x0807;
                    if (signedDescriptor && marker.offset + 16 > static_cast<uint64_t>(input.status.st_size)) continue;
                    if (!signedDescriptor && marker.offset < start + headerSize + 12) continue;
                    const auto position = signedDescriptor ? marker.offset + 4 : marker.offset - 12;
                    const auto fields = repairRead(input, position, 12, job);
                    const auto candidatePacked = repairU32(fields, 4);
                    const auto descriptorStart = signedDescriptor ? marker.offset : position;
                    if (start + headerSize + candidatePacked != descriptorStart) continue;
                    crc = repairU32(fields, 0);
                    packed = candidatePacked;
                    unpacked = repairU32(fields, 8);
                    recordSize = descriptorStart + (signedDescriptor ? 16 : 12) - start;
                    found = true;
                    break;
                }
                if (!found) throw std::runtime_error("未找到大小与记录边界一致的经典数据描述符");
            }
            if (start + recordSize > static_cast<uint64_t>(input.status.st_size)) throw std::runtime_error("压缩数据被截断");
            // 已知大小的条目内部出现 PK 字节序列时，继续按已知边界前进。
            if (unpacked > 512ULL * 1048576 || unpackedTotal + unpacked > 2ULL * 1024 * 1048576) {
                throw std::runtime_error("条目超过 512 MiB 或恢复总量超过 2 GiB");
            }
            const auto candidate = workspace.currentPath() / "candidate.zip";
            const auto central = repairCentral(header, crc, packed, unpacked, 0);
            const auto ending = repairEnd(1, static_cast<uint32_t>(central.size()), static_cast<uint32_t>(recordSize));
            checking = false;
            {
                FilePartOutput temporary(workspace, "candidate.zip");
                repairCopy(input, start, recordSize, temporary, job);
                temporary.write(central.data(), central.size());
                temporary.write(ending.data(), ending.size());
                temporary.finish();
            }
            checking = true;
            struct CandidateCleanup {
                int directory;
                ~CandidateCleanup() { unlinkat(directory, "candidate.zip", 0); }
            } cleanup{workspace.descriptor};
            ZipEncodingScope encoding(engine, candidate.c_str(), job->codePage);
            BitArchiveReader reader(library, candidate.string(), BitFormat::Zip, password);
            callbacks(reader, job);
            const auto items = reader.items();
            if (items.size() != 1) throw std::runtime_error("候选记录不能确定为单个条目");
            const auto& item = items.front();
            label = item.path();
            validateEntry(item);
            const auto name = logicalPath(item.path(), true);
            if (name.empty() || names.count(name)) throw std::runtime_error("空路径或重复路径");
            auto nextUnicode = unicodePaths;
            recordUnicodePath(nextUnicode, name, 2);
            for (auto parent = localfs::path(name).parent_path(); !parent.empty(); parent = parent.parent_path()) {
                if (names.count(parent.generic_string()) && !names.at(parent.generic_string())) throw std::runtime_error("路径位于文件之下");
            }
            if (!item.isDir()) {
                const auto descendant = names.lower_bound(name + "/");
                if (descendant != names.end() && descendant->first.compare(0, name.size() + 1, name + "/") == 0) throw std::runtime_error("文件路径与目录冲突");
            }
            reader.test();
            checkCancellation(job);
            if (recovered >= 10000 || outputSize + recordSize + directory.size() + central.size() + 22 >= UINT32_MAX) {
                throw std::runtime_error("修复结果超过 10000 项或经典 ZIP 大小范围");
            }
            names.emplace(name, item.isDir());
            unicodePaths = std::move(nextUnicode);
        } catch (const RepairReadFailure&) {
            throw;
        } catch (const BitException& error) {
            if (job->cancelled || error.code() == BitFailureSource::WrongPassword) throw;
            ++rejected;
            const auto detail = "{\"entry\":" + quote(label) + ",\"error\":" + quote(error.what()) + '}';
            if (skipped.size() + detail.size() < 1048576) {
                if (skipped.size() > 1) skipped += ',';
                skipped += detail;
            }
            continue;
        } catch (const std::runtime_error& error) {
            if (!checking) throw;
            checkCancellation(job);
            ++rejected;
            const auto detail = "{\"entry\":" + quote(label) + ",\"error\":" + quote(error.what()) + '}';
            if (skipped.size() + detail.size() < 1048576) {
                if (skipped.size() > 1) skipped += ',';
                skipped += detail;
            }
            continue;
        }
        consumed = start + recordSize;
        // 通过验证后再写入最终数据，写入失败必须中止整个修复。
        repairCopy(input, start, recordSize, output, job);
        directory += repairCentral(header, crc, packed, unpacked, static_cast<uint32_t>(outputSize));
        outputSize += recordSize;
        unpackedTotal += unpacked;
        ++recovered;
    }
    if (!recovered) throw std::runtime_error("未找到可通过完整性校验的经典 ZIP 条目，已保留原包");
    const auto ending = repairEnd(recovered, static_cast<uint32_t>(directory.size()), static_cast<uint32_t>(outputSize));
    output.write(directory.data(), directory.size());
    output.write(ending.data(), ending.size());
    output.finish();
    BitArchiveReader verified(library, (staging.currentPath() / target.filename()).string(), BitFormat::Zip, password);
    callbacks(verified, job);
    verified.test();
    validateMutationSources(versions, job);
    ExtractionPermissions permissions;
    struct stat stagedIdentity{};
    if (fstat(staging.descriptor, &stagedIdentity) != 0) throw std::runtime_error("无法验证修复暂存目录");
    publishExtraction(staging.currentPath(), target.parent_path(), job, staging, source, targetIdentity, permissions, sourceVolumes, {}, &stagedIdentity);
    permissions.commit();
    return "{\"ok\":true,\"path\":" + quote(target.string()) + ",\"recovered\":" + std::to_string(recovered) +
        ",\"rejected\":" + std::to_string(rejected) + ",\"skipped\":" + skipped + "]}";
}
