#pragma once

static void validateWindowsArchivePath(const std::string& name) {
    const std::set<std::string> devices = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"};
    for (const auto& component : localfs::path(name)) {
        const auto text = component.string();
        if (text.empty() || text.back() == '.' || text.back() == ' ' ||
            text.find_first_of("<>:\"|?*\\") != std::string::npos ||
            std::any_of(text.begin(), text.end(), [](unsigned char value) { return value < 32; })) {
            throw std::runtime_error("归档包含 Windows 不支持的文件名。" + name);
        }
        const auto key = windowsFilenameKey(text);
        const auto base = key.substr(0, key.find('.'));
        const bool numberedDevice = base.size() == 4 && (base.substr(0, 3) == "COM" || base.substr(0, 3) == "LPT") &&
            base[3] >= '1' && base[3] <= '9';
        const bool superscriptDevice = base == "COM¹" || base == "COM²" || base == "COM³" ||
            base == "LPT¹" || base == "LPT²" || base == "LPT³";
        if (devices.count(base) || numberedDevice || superscriptDevice) throw std::runtime_error("归档包含 Windows 保留设备名。" + name);
    }
}
