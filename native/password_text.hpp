#pragma once

namespace bit7z {
extern thread_local bool f7zipUtf16Passwords;
}

// SFX 面向 Windows 的 UTF-16 密码契约，普通归档沿用已有转换行为。
class PasswordTextScope {
    bool previous = bit7z::f7zipUtf16Passwords;
public:
    void useUtf16() { bit7z::f7zipUtf16Passwords = true; }
    ~PasswordTextScope() { bit7z::f7zipUtf16Passwords = previous; }
};
