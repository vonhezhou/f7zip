#include "zip_encoding.hpp"
#include <algorithm>
#include <array>
#include <fstream>
#include <stdexcept>
#include <vector>
#include <map>
#include <unicode/locid.h>
#include <unicode/ucsdet.h>
#include <unicode/normalizer2.h>
#include <unicode/unistr.h>
#include "zip_encoding_common.hpp"
#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#else
#include <dlfcn.h>
#include <gio/gio.h>
#endif

uint32_t detectZipCodePage(const char* archive) {
    const auto sample = legacyZipNames(archive);
    if (sample.empty()) return 65001;
    UErrorCode error = U_ZERO_ERROR;
    UCharsetDetector* detector = ucsdet_open(&error);
    if (U_FAILURE(error)) throw std::runtime_error("无法创建文件名编码检测器");
    ucsdet_setText(detector, sample.data(), static_cast<int32_t>(sample.size()), &error);
    const UCharsetMatch* match = ucsdet_detect(detector, &error);
    const char* name = match ? ucsdet_getName(match, &error) : nullptr;
    const std::string encoding = name && U_SUCCESS(error) ? name : "";
    ucsdet_close(detector);
    const std::map<std::string, uint32_t> supported = {{"UTF-8", 65001}, {"GB18030", 54936},
        {"Shift_JIS", 932}, {"Big5", 950}, {"EUC-KR", 949}, {"windows-1252", 1252}, {"ISO-8859-1", 1252}};
    const auto found = supported.find(encoding);
    return found == supported.end() ? 437 : found->second;
}

ZipEncodingScope::ZipEncodingScope(const char* engine, const std::filesystem::path& archive, uint32_t requested)
    : handle(nullptr), setCodePage(nullptr), previous(0), selected(requested == 0 ? detectZipCodePage(archive.u8string().c_str()) : requested) {
    const std::array<uint32_t, 8> supported = {65001, 54936, 936, 932, 950, 949, 1252, 437};
    if (std::find(supported.begin(), supported.end(), selected) == supported.end()) throw std::runtime_error("不支持的 ZIP 文件名编码");
#ifdef _WIN32
    handle = LoadLibraryW(std::filesystem::u8path(engine).c_str());
    if (handle) setCodePage = reinterpret_cast<SetCodePage>(GetProcAddress(static_cast<HMODULE>(handle), "f7zip_set_codepage"));
#else
    handle = dlopen(engine, RTLD_LAZY | RTLD_LOCAL);
    if (handle) setCodePage = reinterpret_cast<SetCodePage>(dlsym(handle, "f7zip_set_codepage"));
#endif
    if (!setCodePage) {
#ifdef _WIN32
        if (handle) FreeLibrary(static_cast<HMODULE>(handle));
#else
        if (handle) dlclose(handle);
#endif
        throw std::runtime_error("原生引擎缺少文件名编码支持，请重新构建应用");
    }
    previous = setCodePage(selected);
}

ZipEncodingScope::~ZipEncodingScope() {
    setCodePage(previous);
#ifdef _WIN32
    FreeLibrary(static_cast<HMODULE>(handle));
#else
    dlclose(handle);
#endif
}
void ZipEncodingScope::detectArchive(const std::filesystem::path& archive) { selected = detectZipCodePage(archive.u8string().c_str()); setCodePage(selected); }

static icu::UnicodeString unicodeName(const std::string& value) {
    const auto text = icu::UnicodeString::fromUTF8(value);
    std::string roundTrip;
    text.toUTF8String(roundTrip);
    if (value.find('\0') != std::string::npos || roundTrip != value) throw std::runtime_error("文件名不是有效的 UTF-8");
    return text;
}
std::string normalizeUnicodeName(const std::string& value, uint32_t mode) {
    if (mode == 0) return value;
    if (mode > 2) throw std::runtime_error("无效的 Unicode 文件名规范化选项");
    UErrorCode error = U_ZERO_ERROR;
    const auto* normalizer = mode == 1 ? icu::Normalizer2::getNFCInstance(error) : icu::Normalizer2::getNFDInstance(error);
    icu::UnicodeString normalized;
    if (U_SUCCESS(error)) normalizer->normalize(unicodeName(value), normalized, error);
    if (U_FAILURE(error)) throw std::runtime_error("无法规范化 Unicode 文件名");
    std::string result;
    normalized.toUTF8String(result);
    return result;
}
std::string windowsFilenameKey(const std::string& value) {
    auto text = unicodeName(normalizeUnicodeName(value, 1));
    text.toUpper(icu::Locale::getRoot());
    std::string result;
    text.toUTF8String(result);
    return result;
}

std::string moveArchiveToTrash(const std::string& path) {
#ifdef _WIN32
    auto source = std::filesystem::u8path(path).wstring();
    source.push_back(L'\0');
    SHFILEOPSTRUCTW operation{};
    operation.wFunc = FO_DELETE;
    operation.pFrom = source.c_str();
    operation.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;
    if (SHFileOperationW(&operation) != 0 || operation.fAnyOperationsAborted) throw std::runtime_error("无法移至回收站");
#else
    GFile* file = g_file_new_for_path(path.c_str());
    GError* error = nullptr;
    const bool success = g_file_trash(file, nullptr, &error);
    g_object_unref(file);
    if (!success) {
        const std::string message = error ? error->message : "无法移至回收站";
        if (error) g_error_free(error);
        throw std::runtime_error(message);
    }
#endif
    return {};
}
