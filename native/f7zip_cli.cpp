#include <nlohmann/json.hpp>
#include "f7zip.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <condition_variable>
#include <mutex>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <map>
#include <memory>
#include <cctype>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#ifdef _WIN32
#include <windows.h>
#include <process.h>
#else
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

extern char** environ;
namespace fs = std::filesystem;
static std::atomic<int> interrupted{0};
static_assert(std::atomic<int>::is_always_lock_free, "Signal cancellation requires a lock-free integer");
static void interrupt(int signal) { interrupted.store(signal, std::memory_order_relaxed); }

static const char* usage = R"(F7Zip 命令行
  f7zip open [归档 ...]
  f7zip compress [选项] 输出归档 -- 输入文件或目录 ...
  f7zip extract [选项] 归档 目标目录
  f7zip test [选项] 归档

通用选项
  --quiet                    隐藏 stderr 进度，stdout 保留 JSON 结果
  --password-stdin           从 stdin 读取至 EOF，去掉末尾一个 LF，最多 4096 字节
  --encoding CODEPAGE        ZIP 文件名编码，0 为自动检测
  --normalization MODE       preserve、nfc 或 nfd，用于创建与解压

压缩选项
  --format FORMAT            zip、zipx、wim、sfx、7z、tar、tar.gz、tar.bz2、tar.xz、gz、xz、bz2
                             默认按输出扩展名选择，无扩展名时使用 ZIP
  --level N                  0、1、5（默认）、7、9
  --volume-mib N             ZIP / 7z 分卷，整数 MiB，0 表示不分卷
  --method METHOD            auto、Copy、Deflate、Deflate64、BZip2、LZMA、LZMA2、PPMd
  --dictionary-mib N         0、1、4、8、16、32、64、128、256
  --threads N                0（自动）或 1–64
  --solid-mib N              -1（默认关闭）、0、16、64、256、1024，仅用于 7z
  --zipcrypto                ZIP / ZIPX 使用 ZipCrypto，默认 AES-256
  --visible-names            7z / SFX 保留可见文件名，默认加密文件名

解压选项
  --remove-root              去掉单个冗余根目录

数据操作沿用原生暂存、已有文件保护和取消清理。参数名以 -- 开头的路径放在 -- 后。
退出状态为 0 成功、1 操作失败、2 参数错误、3 需要正确密码、128+信号编号取消。
open 的成功表示系统已接受打开请求。
)";

struct Options {
    std::string command;
    std::vector<std::string> paths;
    std::map<std::string, std::string> values;
    std::set<std::string> flags;
};

static int error(const std::string& message, int status) {
    std::cout << nlohmann::json({{"ok", false}, {"error", message}}).dump() << '\n';
    return status;
}

static Options parse(int argc, const char* const* argv) {
    Options options;
    if (argc < 2) throw std::invalid_argument("请指定命令，使用 --help 查看用法");
    options.command = argv[1];
    const std::set<std::string> commands = {"open", "compress", "extract", "test"};
    if (!commands.count(options.command)) throw std::invalid_argument("未知命令，使用 --help 查看用法");
    const std::set<std::string> flags = {"--quiet", "--password-stdin", "--zipcrypto", "--visible-names", "--remove-root"};
    const std::set<std::string> values = {"--format", "--level", "--volume-mib", "--method", "--dictionary-mib",
        "--threads", "--solid-mib", "--encoding", "--normalization"};
    bool pathsOnly = false;
    for (int index = 2; index < argc; ++index) {
        const std::string argument(argv[index]);
        if (!pathsOnly && argument == "--") { pathsOnly = true; continue; }
        if (!pathsOnly && argument.rfind("--", 0) == 0) {
            if (options.flags.count(argument) || options.values.count(argument)) throw std::invalid_argument("选项不能重复");
            if (flags.count(argument)) options.flags.insert(argument);
            else if (values.count(argument)) {
                if (++index == argc || std::string(argv[index]).rfind("--", 0) == 0) throw std::invalid_argument("选项缺少参数值");
                options.values[argument] = argv[index];
            } else throw std::invalid_argument("未知选项，使用 --help 查看用法");
        } else options.paths.push_back(argument);
    }
    const std::set<std::string> compressionOnly = {"--format", "--level", "--volume-mib", "--method", "--dictionary-mib",
        "--threads", "--solid-mib", "--zipcrypto", "--visible-names"};
    for (const auto& [key, value] : options.values) {
        if (options.command != "compress" && compressionOnly.count(key)) throw std::invalid_argument("压缩参数仅用于 compress");
    }
    for (const auto& flag : options.flags) {
        if (options.command != "compress" && compressionOnly.count(flag)) throw std::invalid_argument("压缩参数仅用于 compress");
    }
    if (options.flags.count("--remove-root") && options.command != "extract") throw std::invalid_argument("--remove-root 仅用于 extract");
    if (options.command == "open" && (!options.values.empty() || options.flags.count("--password-stdin"))) {
        throw std::invalid_argument("open 通过应用窗口配置归档选项");
    }
    if ((options.command == "compress" && options.paths.size() < 2) ||
        (options.command == "extract" && options.paths.size() != 2) ||
        (options.command == "test" && options.paths.size() != 1)) {
        throw std::invalid_argument("输入或输出路径数量不正确，使用 --help 查看用法");
    }
    if (options.values.count("--encoding") && options.command != "extract" && options.command != "test") {
        throw std::invalid_argument("--encoding 仅用于 extract 或 test");
    }
    if (options.values.count("--normalization") && options.command != "compress" && options.command != "extract") {
        throw std::invalid_argument("文件名规范化仅用于 compress 或 extract");
    }
    return options;
}

static std::string value(const Options& options, const std::string& key, const std::string& fallback) {
    const auto found = options.values.find(key);
    return found == options.values.end() ? fallback : found->second;
}

static int integer(const Options& options, const std::string& key, int fallback, int minimum, int maximum) {
    const auto found = options.values.find(key);
    if (found == options.values.end()) return fallback;
    const auto& text = found->second;
    size_t count = 0;
    long number;
    try { number = std::stol(text, &count); }
    catch (const std::exception&) { throw std::invalid_argument("整数参数无效。" + key); }
    if (count != text.size() || number < minimum || number > maximum) throw std::invalid_argument("整数参数超出范围。" + key);
    return static_cast<int>(number);
}

static std::string compressionFormat(const Options& options) {
    const std::vector<std::string> formats = {"tar.gz", "tar.bz2", "tar.xz", "zipx", "wim", "sfx", "zip", "7z", "tar", "gz", "xz", "bz2"};
    auto format = value(options, "--format", "");
    if (format.empty()) {
        auto output = options.paths.front();
        std::transform(output.begin(), output.end(), output.begin(), [](unsigned char byte) { return std::tolower(byte); });
        for (const auto& candidate : formats) {
            const auto suffix = candidate == "sfx" ? ".exe" : "." + candidate;
            if (output.size() >= suffix.size() && output.compare(output.size() - suffix.size(), suffix.size(), suffix) == 0) {
                format = candidate;
                break;
            }
        }
        if (format.empty() && !fs::path(output).has_extension()) format = "zip";
    }
    if (std::find(formats.begin(), formats.end(), format) == formats.end()) throw std::invalid_argument("请指定支持的压缩格式");
    if (options.flags.count("--zipcrypto") && format != "zip" && format != "zipx") throw std::invalid_argument("--zipcrypto 仅用于 ZIP / ZIPX");
    if (options.flags.count("--visible-names") && format != "7z" && format != "sfx") throw std::invalid_argument("--visible-names 仅用于 7z / SFX");
    if ((format == "zip" || format == "zipx") && !options.flags.count("--zipcrypto")) return format + "-aes256";
    if ((format == "7z" || format == "sfx") && options.flags.count("--visible-names")) return format + "-visible";
    return format;
}

static fs::path executable() {
#ifdef _WIN32
    std::vector<wchar_t> path(32768);
    const auto size = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (!size || size == path.size()) throw std::runtime_error("无法定位命令行程序");
    return fs::canonical(fs::path(std::wstring(path.data(), size)));
#else
    return fs::canonical("/proc/self/exe");
#endif
}

#ifdef _WIN32
// CRT spawn 直接拼接参数，需要按 Windows argv 规则保护空格、引号与尾部反斜杠。
static std::wstring quoteWindowsArgument(const std::wstring& value) {
    std::wstring quoted = L"\"";
    size_t backslashes = 0;
    for (const auto character : value) {
        if (character == L'\\') { ++backslashes; continue; }
        quoted.append(character == L'\"' ? backslashes * 2 + 1 : backslashes, L'\\');
        quoted.push_back(character);
        backslashes = 0;
    }
    quoted.append(backslashes * 2, L'\\');
    quoted.push_back(L'\"');
    return quoted;
}
#endif

static int openApplication(const fs::path& binary, const Options& options) {
    const auto application = binary.parent_path() /
#ifdef _WIN32
        "F7Zip.exe";
    std::vector<std::wstring> arguments = {quoteWindowsArgument(application.wstring())};
    for (const auto& path : options.paths) arguments.push_back(quoteWindowsArgument(fs::u8path(path).wstring()));
    std::vector<const wchar_t*> pointers;
    for (const auto& argument : arguments) pointers.push_back(argument.c_str());
    pointers.push_back(nullptr);
    if (_wspawnv(_P_DETACH, application.c_str(), pointers.data()) == -1) throw std::runtime_error("无法启动 F7Zip");
#else
        "F7Zip";
    std::vector<std::string> arguments = {application.string()};
    arguments.insert(arguments.end(), options.paths.begin(), options.paths.end());
    std::vector<char*> pointers;
    for (auto& argument : arguments) pointers.push_back(argument.data());
    pointers.push_back(nullptr);
    pid_t process;
    if (posix_spawn(&process, application.c_str(), nullptr, nullptr, pointers.data(), environ) != 0) throw std::runtime_error("无法启动 F7Zip");
#endif
    std::cout << "{\"ok\":true,\"accepted\":true}\n";
    return 0;
}

static int run(const Options& options) {
    const auto binary = executable();
    if (options.command == "open") return openApplication(binary, options);
    auto engineDirectory = binary.parent_path();
    #ifdef _WIN32
    const char* engineName = "7z.dll";
#else
    const char* engineName = "7z.so";
    if (!fs::is_regular_file(engineDirectory / engineName)) engineDirectory /= "lib";
#endif
    const auto engine = (engineDirectory / engineName).u8string();
    const auto format = options.command == "compress" ? compressionFormat(options) : "zip";
    const int level = integer(options, "--level", format == "wim" ? 0 : 5, 0, 9);
    if (!std::set<int>{0, 1, 5, 7, 9}.count(level)) throw std::invalid_argument("压缩等级仅支持 0、1、5、7、9");
    const auto normalization = value(options, "--normalization", "preserve");
    const std::map<std::string, uint32_t> modes = {{"preserve", 0}, {"nfc", 1}, {"nfd", 2}};
    if (!modes.count(normalization)) throw std::invalid_argument("无效的文件名规范化选项");
    std::string password;
    if (options.flags.count("--password-stdin")) {
        char byte;
        while (std::cin.get(byte)) {
            password.push_back(byte);
            if (password.size() > 4097) throw std::invalid_argument("密码超过 4096 字节");
        }
        if (std::cin.bad()) throw std::runtime_error("无法读取 stdin 密码");
        if (!password.empty() && password.back() == '\n') password.pop_back();
        if (password.size() > 4096 || password.find('\0') != std::string::npos) throw std::invalid_argument("密码超出长度限制或含空字符");
    }
    std::unique_ptr<F7Job, decltype(&f7_job_destroy)> ownedJob(f7_job_create(), f7_job_destroy);
    F7Job* job = ownedJob.get();
    f7_job_codepage(job, integer(options, "--encoding", 0, 0, 65001));
    f7_job_filename_normalization(job, modes.at(normalization));
    f7_job_volume_size(job, static_cast<uint64_t>(integer(options, "--volume-mib", 0, 0, 2097151)) * 1048576);
    const auto method = value(options, "--method", "auto");
    f7_job_compression_parameters(job, method.c_str(), integer(options, "--dictionary-mib", 0, 0, 256),
        integer(options, "--threads", 0, 0, 64), integer(options, "--solid-mib", -1, -1, 1024));
    std::vector<const char*> inputs;
    if (options.command == "compress") {
        for (size_t index = 1; index < options.paths.size(); ++index) inputs.push_back(options.paths[index].c_str());
    }
    auto operation = options.command;
    if (operation == "extract" && options.flags.count("--remove-root")) operation = "extractFlat";
    const auto destination = options.command == "extract" ? options.paths[1] : "";
    std::string response;
    std::atomic<bool> complete{false};
    std::mutex completionMutex;
    std::condition_variable completionChanged;
    const auto previousInt = std::signal(SIGINT, interrupt);
    const auto previousTerm = std::signal(SIGTERM, interrupt);
    std::thread worker([&] {
        char* result = f7_run(job, engine.c_str(), operation.c_str(), options.paths[0].c_str(), destination.c_str(),
            password.c_str(), format.c_str(), level, inputs.data(), static_cast<int>(inputs.size()), nullptr, 0);
        response = result ? result : "{\"ok\":false,\"error\":\"原生引擎未返回结果\"}";
        f7_free(result);
        {
            std::lock_guard<std::mutex> guard(completionMutex);
            complete.store(true, std::memory_order_release);
        }
        completionChanged.notify_one();
    });
    std::string lastProgress;
    while (!complete.load(std::memory_order_acquire)) {
        if (interrupted.load(std::memory_order_relaxed)) f7_job_cancel(job);
        if (!options.flags.count("--quiet")) {
            char* progress = f7_job_progress(job);
            const std::string current = progress ? progress : "";
            f7_free(progress);
            if (!current.empty() && current != lastProgress) {
                std::cerr << current << '\n';
                lastProgress = current;
            }
        }
        std::unique_lock<std::mutex> guard(completionMutex);
        completionChanged.wait_for(guard, std::chrono::milliseconds(100), [&] {
            return complete.load(std::memory_order_acquire);
        });
    }
    worker.join();
    std::signal(SIGINT, previousInt);
    std::signal(SIGTERM, previousTerm);
    volatile char* passwordBytes = password.data();
    for (size_t index = 0; index < password.size(); ++index) passwordBytes[index] = 0;
    const auto result = nlohmann::json::parse(response, nullptr, false);
    if (!result.is_object() || !result.contains("ok") || !result["ok"].is_boolean()) return error("原生引擎返回了无效结果", 1);
    std::cout << response << '\n';
    if (result["ok"].get<bool>()) return 0;
    const int signal = interrupted.load(std::memory_order_relaxed);
    if (result.value("cancelled", false)) return signal ? 128 + signal : 130;
    return result.value("passwordRequired", false) ? 3 : 1;
}

int main(int argc, char** argv) {
    {
        if ((argc == 2 && (std::string(argv[1]) == "--help" || std::string(argv[1]) == "help")) ||
            (argc == 3 && std::string(argv[2]) == "--help")) {
            std::cout << usage;
            return 0;
        }
        try { return run(parse(argc, argv)); }
        catch (const std::invalid_argument& failure) { return error(failure.what(), 2); }
        catch (const std::exception& failure) { return error(failure.what(), 1); }
    }
}
