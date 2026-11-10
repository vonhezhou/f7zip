// F7Zip 对 7-Zip POSIX 的 ZIP 文件名解码补充，原始源码随源码包一同分发。
#include <iconv.h>
#include <stdexcept>
#include <string>
#include "../../../Common/UTFConvert.h"

static thread_local UInt32 f7zipCodePage = 0;

extern "C" __attribute__((visibility("default"))) UInt32 f7zip_set_codepage(UInt32 codePage) {
    const auto previous = f7zipCodePage;
    f7zipCodePage = codePage;
    return previous;
}

static void f7zipDecodeLegacy(UString& result, const AString& input, UInt32 codePage) {
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
}
