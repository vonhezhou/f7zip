// F7Zip 对 7-Zip POSIX 的 ZIP 文件名解码补充，原始源码随源码包一同分发。
#ifdef _WIN32
#include <windows.h>
#define F7ZIP_EXPORT __declspec(dllexport)
#else
#include <iconv.h>
#define F7ZIP_EXPORT __attribute__((visibility("default")))
#endif
#include <stdexcept>
#include <string>
#include "../../../Common/UTFConvert.h"

static thread_local UInt32 f7zipCodePage = 0;

extern "C" F7ZIP_EXPORT UInt32 f7zip_set_codepage(UInt32 codePage) {
    const auto previous = f7zipCodePage;
    f7zipCodePage = codePage;
    return previous;
}

static void f7zipDecodeLegacy(UString& result, const AString& input, UInt32 codePage) {
#ifdef _WIN32
    const int size = MultiByteToWideChar(codePage, 0, input.Ptr(), input.Len(), nullptr, 0);
    if (size == 0 && input.Len()) throw std::runtime_error("Invalid ZIP filename encoding");
    std::wstring text(static_cast<size_t>(size), L'\0');
    if (size && !MultiByteToWideChar(codePage, 0, input.Ptr(), input.Len(), text.data(), size)) throw std::runtime_error("Invalid ZIP filename encoding");
    result.SetFrom(text.c_str(), static_cast<unsigned>(text.size()));
#else
    const char* encoding;
    switch (codePage) {
        case 437: encoding = "CP437"; break;
        case 932: encoding = "CP932"; break;
        case 936: encoding = "GBK"; break;
        case 949: encoding = "CP949"; break;
        case 950: encoding = "BIG5"; break;
        case 1252: encoding = "WINDOWS-1252"; break;
        case 54936: encoding = "GB18030"; break;
        default: throw std::runtime_error("Unsupported ZIP filename encoding");
    }
    std::string buffer(static_cast<size_t>(input.Len()) * 4 + 4, '\0');
    iconv_t converter = iconv_open("UTF-8", encoding);
    if (converter == reinterpret_cast<iconv_t>(-1)) throw std::runtime_error("Cannot open ZIP filename decoder");
    char* source = const_cast<char*>(input.Ptr());
    char* destination = &buffer[0];
    size_t sourceLeft = input.Len();
    size_t destinationLeft = buffer.size() - 1;
    const auto converted = iconv(converter, &source, &sourceLeft, &destination, &destinationLeft);
    iconv_close(converter);
    if (converted == static_cast<size_t>(-1) || sourceLeft != 0) {
        throw std::runtime_error("Invalid ZIP filename encoding");
    }
    if (!ConvertUTF8ToUnicode(AString(buffer.c_str()), result)) throw std::runtime_error("Invalid decoded ZIP filename");
#endif
}

// 归档注释没有 UTF-8 标志，有效 UTF-8 优先，否则沿用所选旧编码。
void f7zipDecodeZipComment(UString& result, const AString& input) {
    if (CheckUTF8_AString(input) && ConvertUTF8ToUnicode(input, result)) return;
    f7zipDecodeLegacy(result, input, f7zipCodePage && f7zipCodePage != CP_UTF8 ? f7zipCodePage : 437);
}
