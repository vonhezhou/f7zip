#!/usr/bin/env python3
"""下载固定版本源码，编译本机架构的 7-Zip 与 C ABI 桥接库。"""
import concurrent.futures
import hashlib
import os
import platform
import re
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'native/vendor'
ENGINE_VERSION = '26.06'
SOURCE_ARCHIVE = VENDOR / f'7z{ENGINE_VERSION.replace(".", "")}-src.tar.xz'
SOURCE_URL = f'https://github.com/ip7z/7zip/releases/download/{ENGINE_VERSION}/{SOURCE_ARCHIVE.name}'
CODEPAGE_HEADER = ROOT / 'native/7zip_codepage.hpp'
RAR_COMMENTS_HEADER = ROOT / 'native/7zip_rar_comments.hpp'
ENGINE_PATCH = hashlib.sha256(CODEPAGE_HEADER.read_bytes() + RAR_COMMENTS_HEADER.read_bytes() + Path(__file__).read_bytes()).hexdigest()[:12]
ENGINE = VENDOR / f'7zip-{ENGINE_VERSION}-{ENGINE_PATCH}'
BIT7Z = VENDOR / 'bit7z'
LIB = ROOT / 'native/lib'
OBJECTS = VENDOR / f'objects-{platform.system()}-{platform.machine()}-{ENGINE_VERSION}-{ENGINE_PATCH}'
SOURCE_HASH = 'a4e374c8f864f51df48c2cfd0e1413ec3b2ea030deae852d6a655402ebb61ac4'
BIT7Z_SOURCE_HASH = '5a79f9cd2f7bc17ae4088a6b7ac9b5b08476082c1404c98c50ae52aa441559ae'
BIT7Z_COMMIT = '0f03717920442abcdba80183534931c867feb9c0'


def run(args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def bundle_windows_dependencies():
    """从构建工具链递归收集实际引用的 DLL，避免发布包依赖 MSYS2 的 PATH。"""
    directory = ROOT / 'native/lib'
    pending = list(directory.glob('*.dll')) + list(directory.glob('*.exe'))
    visited = set()
    search_paths = [Path(value.strip('"')) for value in os.environ.get('PATH', '').split(os.pathsep) if value]
    while pending:
        binary = pending.pop()
        if binary.name.lower() in visited:
            continue
        visited.add(binary.name.lower())
        imports = subprocess.check_output(['objdump', '-p', str(binary)], text=True)
        for name in re.findall(r'DLL Name:\s*(\S+)', imports):
            source = next((path / name for path in search_paths if (path / name).is_file()), None)
            if source is None or source.parent.name.lower() == 'system32':
                continue
            target = directory / name
            if not target.exists():
                shutil.copy2(source, target)
                pending.append(target)



def main():
    VENDOR.mkdir(parents=True, exist_ok=True)
    LIB.mkdir(parents=True, exist_ok=True)
    OBJECTS.mkdir(parents=True, exist_ok=True)
    archive = SOURCE_ARCHIVE
    bundled_engine = ROOT / 'third_party/7zip.tar.xz'
    if not archive.exists() and bundled_engine.exists():
        shutil.copy2(bundled_engine, archive)
    if not archive.exists():
        with tempfile.TemporaryDirectory(prefix='.download-', dir=VENDOR) as directory:
            downloaded = Path(directory) / archive.name
            urllib.request.urlretrieve(SOURCE_URL, downloaded)
            if hashlib.sha256(downloaded.read_bytes()).hexdigest() != SOURCE_HASH:
                raise RuntimeError('下载的 7-Zip 源码校验失败')
            downloaded.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SOURCE_HASH:
        raise RuntimeError(f'7-Zip 源码校验失败，请检查 {archive}')
    if not ENGINE.exists():
        with tempfile.TemporaryDirectory(prefix='.source-', dir=VENDOR) as directory:
            unpacked = Path(directory) / 'source'
            unpacked.mkdir()
            with tarfile.open(archive) as source:
                source.extractall(unpacked)
            zip_source = unpacked / 'CPP/7zip/Archive/Zip/ZipItem.cpp'
            content = zip_source.read_bytes()
            include = b'#include "ZipItem.h"'
            conversion = b'  MultiByteToUnicodeString2(res, s, useSpecifiedCodePage ? codePage : GetCodePage());'
            if content.count(include) != 1 or content.count(conversion) != 1:
                raise RuntimeError('7-Zip ZIP 解码补丁上下文不匹配')
            content = content.replace(include, include + b'\r\n#include "F7ZipCodePage.h"')
            content = content.replace(
                b'  bool isUtf8 = IsUtf8();',
                b'  if (f7zipCodePage != 0) { codePage = f7zipCodePage; useSpecifiedCodePage = true; }\r\n  bool isUtf8 = IsUtf8();',
            )
            content = content.replace(conversion,
                b'  if (useSpecifiedCodePage && codePage != CP_UTF8) { f7zipDecodeLegacy(res, s, codePage); return; }\r\n' + conversion)
            zip_source.chmod(zip_source.stat().st_mode | 0o200)
            zip_source.write_bytes(content)
            shutil.copy2(CODEPAGE_HEADER, zip_source.parent / 'F7ZipCodePage.h')
            zip_writer = zip_source.parent / 'ZipHandlerOut.cpp'
            content = zip_writer.read_bytes()
            comment_property = b'        RINOK(callback->GetProperty(i, kpidComment, &prop))'
            unicode_comment = b'          UString s = prop.bstrVal;\r\n          AString a;'
            if content.count(comment_property) != 1 or content.count(unicode_comment) != 1:
                raise RuntimeError('7-Zip ZIP 注释补丁上下文不匹配')
            content = content.replace(comment_property, comment_property + b'''\r
        // F7Zip: preserve comments when replacing data or renaming entries.\r
        if (prop.vt == VT_EMPTY && existInArchive)\r
        {\r
          const CItemEx &oldItem = m_Items[indexInArc];\r
          AString raw;\r
          raw.SetFrom_CalcLen((const char *)(const Byte *)oldItem.Comment, (unsigned)oldItem.Comment.Size());\r
          UString text;\r
          oldItem.GetUnicodeString(text, raw, true, _forceCodePage, _specifiedCodePage);\r
          prop = text;\r
        }''')
            content = content.replace(unicode_comment, unicode_comment + b'''\r
          // F7Zip: UTF-8 comments also require a UTF-8 filename and flag.\r
          if (!s.IsAscii() && !ui.IsUtf8)\r
          {\r
            ui.IsUtf8 = true;\r
            ConvertUnicodeToUTF8(name, ui.Name);\r
          }''')
            zip_writer.chmod(zip_writer.stat().st_mode | 0o200)
            zip_writer.write_bytes(content)
            zip_reader = zip_source.parent / 'ZipHandler.cpp'
            content = zip_reader.read_bytes()
            declaration = b'#include "ZipHandler.h"'
            archive_comment = b'    case kpidComment:  if (m_Archive.ArcInfo.Comment.Size() != 0) prop = MultiByteToUnicodeString(BytesToString(m_Archive.ArcInfo.Comment), CP_ACP); break;'
            if content.count(declaration) != 1 or content.count(archive_comment) != 1:
                raise RuntimeError('7-Zip ZIP 归档注释补丁上下文不匹配')
            content = content.replace(declaration, declaration + b'\r\nvoid f7zipDecodeZipComment(UString&, const AString&);')
            content = content.replace(archive_comment, b'    case kpidComment: if (m_Archive.ArcInfo.Comment.Size() != 0) { UString text; f7zipDecodeZipComment(text, BytesToString(m_Archive.ArcInfo.Comment)); prop = text; } break;')
            zip_reader.chmod(zip_reader.stat().st_mode | 0o200)
            zip_reader.write_bytes(content)
            rar_directory = unpacked / 'CPP/7zip/Archive/Rar'
            shutil.copy2(RAR_COMMENTS_HEADER, rar_directory / 'F7ZipRarComments.h')
            rar_patches = {
                'RarItem.h': [
                    (b'#include "RarHeader.h"', b'#include "RarHeader.h"\r\n#include "../../../Common/MyBuffer.h"'),
                    (b'  UInt16 CommentSize;', b'  UInt16 CommentSize;\r\n  CByteBuffer Comment;'),
                ],
                'RarHandler.h': [
                    (b'  Byte EncryptVersion;', b'  Byte EncryptVersion;\r\n  CByteBuffer Comment;'),
                ],
                'RarHandler.cpp': [
                    (b'#include "RarHandler.h"', b'#include "RarHandler.h"\r\n#include "F7ZipRarComments.h"'),
                    (b'  AddToSeekValue(commentSize);', b'  AddToSeekValue(commentSize);\r\n  ArcInfo.Comment = _comment;'),
                    (b'  item.CommentSize = (UInt16)(m_BlockHeader.HeadSize - fileHeaderWithNameSize);',
                     b'  item.CommentSize = (UInt16)(m_BlockHeader.HeadSize - fileHeaderWithNameSize);\r\n  item.Comment.CopyFrom((const Byte *)m_FileHeaderData + fileHeaderWithNameSize, item.CommentSize);'),
                    (b'    if (m_BlockHeader.Type == NHeader::NBlockType::kFileHeader\r\n        /* || m_BlockHeader.Type == NHeader::NBlockType::kSubBlock */)', b'''    bool commentBlock = false;\r
    if (m_BlockHeader.Type == NHeader::NBlockType::kSubBlock && m_BlockHeader.HeadSize >= 35)\r
    {\r
      m_FileHeaderData.ChangeSize_KeepData(m_BlockHeader.HeadSize, 7);\r
      if (!ReadBytesAndTestSize(m_FileHeaderData + 7, m_BlockHeader.HeadSize - 7)) return S_FALSE;\r
      commentBlock = Get16((const Byte *)m_FileHeaderData + 26) == 3 &&\r
          memcmp((const Byte *)m_FileHeaderData + 32, "CMT", 3) == 0;\r
      if (m_CryptoMode) m_CryptoPos = 7;\r
      else RINOK(InStream_SeekSet(m_Stream, m_Position + 7))\r
    }\r
    if (m_BlockHeader.Type == NHeader::NBlockType::kFileHeader || commentBlock)'''),
                    (b'        if (!CheckHeaderCrc(m_FileHeaderData, (unsigned)m_BlockHeader.HeadSize - item.CommentSize))', b'        if (!commentBlock && !CheckHeaderCrc(m_FileHeaderData, (unsigned)m_BlockHeader.HeadSize - item.CommentSize))'),
                    (b'        filled = true;', b'        filled = !commentBlock;'),
                    (b'      bool okItem = ReadHeaderReal(m_FileHeaderData + 7, m_BlockHeader.HeadSize - 7, item);', b'      bool okItem = ReadHeaderReal(m_FileHeaderData + 7, m_BlockHeader.HeadSize - 7, item);\r\n      if (commentBlock && !okItem) return S_FALSE;'),
                    (b'      AddToSeekValue(item.PackSize);  // m_Position points to next header;', b'''      if (commentBlock && okItem && !item.IsEncrypted() && !item.IsSplitBefore() && !item.IsSplitAfter() &&\r
          item.PackSize <= (1 << 18) && item.Size <= (1 << 18) &&\r
          CheckHeaderCrc(m_FileHeaderData, m_BlockHeader.HeadSize))\r
      {\r
        ArcInfo.Comment.CopyFrom(m_FileHeaderData, m_BlockHeader.HeadSize);\r
        ArcInfo.Comment.ChangeSize_KeepData(m_BlockHeader.HeadSize + (size_t)item.PackSize, m_BlockHeader.HeadSize);\r
        RINOK(ReadStream_FALSE(m_Stream, (Byte *)ArcInfo.Comment + m_BlockHeader.HeadSize, (size_t)item.PackSize))\r
      }\r
      AddToSeekValue(item.PackSize);  // m_Position points to next header;\r
      if (commentBlock) continue;'''),
                    (b'  kpidCommented,', b'  kpidCommented,\r\n  kpidComment,'),
                    (b'  kpidNumVolumes\r\n', b'  kpidNumVolumes,\r\n  kpidComment\r\n'),
                    (b'    case kpidCommented: prop = item.IsCommented(); break;', b'''    case kpidCommented: prop = item.IsCommented(); break;\r
    case kpidComment:\r
    {\r
      CMyComPtr<ICompressCoder> decoder;\r
      const UInt32 coder = f7zipRarCommentCoder(item.Comment);\r
      if (coder && CreateCoder_Id(EXTERNAL_CODECS_VARS coder, false, decoder) != S_OK) break;\r
      UString text;\r
      if (f7zipReadRarComment(item.Comment, decoder, text)) prop = text;\r
      break;\r
    }'''),
                    (b'    case kpidSolid: prop = _arcInfo.IsSolid(); break;', b'''    case kpidSolid: prop = _arcInfo.IsSolid(); break;\r
    case kpidComment:\r
    {\r
      CMyComPtr<ICompressCoder> decoder;\r
      const UInt32 coder = f7zipRarCommentCoder(_arcInfo.Comment);\r
      if (coder && CreateCoder_Id(EXTERNAL_CODECS_VARS coder, false, decoder) != S_OK) break;\r
      UString text;\r
      if (f7zipReadRarComment(_arcInfo.Comment, decoder, text)) prop = text;\r
      break;\r
    }'''),
                ],
            }
            for filename, replacements in rar_patches.items():
                path = rar_directory / filename
                content = path.read_bytes()
                for before, after in replacements:
                    if content.count(before) != 1:
                        raise RuntimeError(f'7-Zip RAR 注释补丁上下文不匹配。{filename}')
                    content = content.replace(before, after)
                path.chmod(path.stat().st_mode | 0o200)
                path.write_bytes(content)
            unpacked.rename(ENGINE)
    bundled_bit7z = ROOT / 'third_party/bit7z-source.tar.gz'
    if not BIT7Z.exists():
        if bundled_bit7z.exists():
            if hashlib.sha256(bundled_bit7z.read_bytes()).hexdigest() != BIT7Z_SOURCE_HASH:
                raise RuntimeError('bit7z 源码校验失败')
            with tarfile.open(bundled_bit7z) as source:
                source.extractall(VENDOR)
        else:
            for attempt in range(3):
                try:
                    with tempfile.TemporaryDirectory(prefix='.bit7z-', dir=VENDOR) as directory:
                        downloaded = Path(directory) / 'bit7z'
                        run(['git', 'clone', '--depth', '1', '--branch', 'v4.0.10',
                             'https://github.com/rikyoz/bit7z.git', downloaded])
                        downloaded.rename(BIT7Z)
                    break
                except subprocess.CalledProcessError:
                    if attempt == 2:
                        raise
                    time.sleep(2)
    if (BIT7Z / '.git').exists():
        commit = subprocess.check_output(['git', '-C', str(BIT7Z), 'rev-parse', 'HEAD'], text=True).strip()
        if commit != BIT7Z_COMMIT:
            raise RuntimeError('bit7z 版本不匹配')
    string_header = BIT7Z / 'src/internal/stringutil.hpp'
    content = string_header.read_bytes()
    for before, after in [
        (b'auto widen( const std::string& narrowString ) -> std::wstring;',
         b'auto widen( const std::string& narrowString ) -> std::wstring;\r\nauto widen_archive_text( const std::string& value ) -> std::wstring;'),
        (b'return WIDEN( path.string< tchar >() );',
         b'return widen_archive_text( path.string< tchar >() );'),
    ]:
        if after in content:
            continue
        if content.count(before) != 1:
            raise RuntimeError('bit7z Unicode 路径补丁上下文不匹配')
        content = content.replace(before, after)
    if content != string_header.read_bytes():
        string_header.chmod(string_header.stat().st_mode | 0o200)
        string_header.write_bytes(content)
    # macOS 15 的 libc++ 无缓冲文件流逐字节读写，分卷处理会产生数百万次系统调用。
    for filename in ('cfileinstream.cpp', 'cfileoutstream.cpp'):
        stream_source = BIT7Z / 'src/internal' / filename
        content = stream_source.read_bytes()
        before = b'    mFileStream.rdbuf()->pubsetbuf( nullptr, 0 );'
        after = b'#ifndef __APPLE__\n' + before + b'\n#endif'
        if after not in content:
            if content.count(before) != 2:
                raise RuntimeError('bit7z 文件流缓冲补丁上下文不匹配')
            content = content.replace(before, after)
        if filename == 'cfileoutstream.cpp':
            before = b'    std::error_code error;\n    fs::resize_file('
            after = (b'#ifdef __APPLE__\n    mFileStream.flush();\n'
                     b'    if ( mFileStream.fail() ) return E_FAIL;\n#endif\n' + before)
            if after not in content:
                if content.count(before) != 1:
                    raise RuntimeError('bit7z 文件流截断补丁上下文不匹配')
                content = content.replace(before, after)
        if content != stream_source.read_bytes():
            stream_source.chmod(stream_source.stat().st_mode | 0o200)
            stream_source.write_bytes(content)
    output_source = BIT7Z / 'src/internal/cstdoutstream.cpp'
    content = output_source.read_bytes()
    before = b'    if ( processedSize != nullptr ) {\n        *processedSize = static_cast< uint32_t >( mOutputStream.tellp() - oldPos );'
    after = (b'#ifdef __APPLE__\n    mOutputStream.flush();\n#endif\n\n' + before)
    if after not in content:
        if content.count(before) != 1:
            raise RuntimeError('bit7z 文件流写入检查补丁上下文不匹配')
        # 每次块写入后检查实际落盘错误，避免析构时刷新失败仍报告成功。
        output_source.chmod(output_source.stat().st_mode | 0o200)
        output_source.write_bytes(content.replace(before, after))
    bundle = ENGINE / 'CPP/7zip/Bundles/Format7zF'
    macos = platform.system() == 'Darwin'
    windows = platform.system() == 'Windows'
    compiler = os.environ.get('CXX', 'clang++' if macos or windows else 'g++')
    c_compiler = os.environ.get('CC', 'clang' if macos or windows else 'gcc')
    deployment_stamp = bundle / f'_o/f7zip-{platform.system()}-{platform.machine()}'
    if not deployment_stamp.exists():
        shutil.rmtree(bundle / '_o', ignore_errors=True)
    build_env = dict(os.environ)
    if macos:
        build_env['MACOSX_DEPLOYMENT_TARGET'] = '12.0'
    make_arguments = ['make', f'-j{min(os.cpu_count() or 2, 8)}', '-f', 'makefile.gcc', f'CXX={compiler}', f'CC={c_compiler}']
    if windows:
        # 引擎与桥接共享 C++ 运行库，打包时递归收集所需 DLL。
        make_arguments += ['IS_MINGW=1', 'IS_X64=1', 'LDFLAGS_STATIC_2=']
    else:
        make_arguments += ['LIB2=-lpthread -ldl' + (' -liconv' if macos else '')]
    run(make_arguments, cwd=bundle, env=build_env)
    deployment_stamp.touch()
    engine_name = '7z.dll' if windows else '7z.so'
    shutil.copy2(bundle / '_o' / engine_name, LIB / engine_name)
    flags = ['-std=c++17', '-O2', '-fPIC',
             '-DBIT7Z_AUTO_FORMAT', '-DBIT7Z_DETECT_FROM_EXTENSION', '-DUNICODE', '-D_UNICODE',
             '-D_LARGEFILE64_SOURCE', '-D_LARGEFILE_SOURCE', '-D_REENTRANT',
             '-DEXTERNAL_CODECS', '-DBREAK_HANDLER', '-DUSE_WIN_FILE',
             '-I' + str(BIT7Z / 'include'), '-I' + str(BIT7Z / 'include/bit7z'),
             '-I' + str(BIT7Z / 'src'), '-I' + str(ENGINE / 'CPP'), '-I' + str(ENGINE)]
    if macos:
        flags += ['-mmacosx-version-min=12.0']
    if not windows:
        flags += ['-DENV_UNIX']
    if windows:
        flags += ['-DNOMINMAX', '-D_WIN32_WINNT=0x0A00']
    libraries = []
    if not macos:
        packages = ['icu-uc', 'icu-i18n'] + ([] if windows else ['gio-2.0'])
        flags += subprocess.check_output(['pkg-config', '--cflags', *packages], text=True).split()
        libraries = subprocess.check_output(['pkg-config', '--libs', *packages], text=True).split()
        libraries += ['-lole32', '-loleaut32', '-lshell32', '-luuid', '-ladvapi32'] if windows else ['-ldl', '-lpthread']
    # 使用保留 MPL 许可证的本地实现，向 TAR 写入器提供 POSIX 权限。
    sources = [source for source in sorted((BIT7Z / 'src').rglob('*.cpp'))
               if source not in {BIT7Z / 'src/internal/genericinputitem.cpp',
                                 BIT7Z / 'src/internal/stringutil.cpp'}]
    sources += [ROOT / 'native/bit7z_genericinputitem.cpp',
                ROOT / 'native/bit7z_stringutil.cpp',
                ROOT / 'native/f7zip.cpp', ROOT / ('native/zip_encoding.mm' if macos else 'native/zip_encoding.cpp'),
                ROOT / ('native/file_parts_manifest.mm' if macos else 'native/file_parts_manifest.cpp')]

    header_time = max(path.stat().st_mtime for pattern in ('*.h', '*.hpp')
                      for path in (ROOT / 'native').glob(pattern))

    def compile_source(source):
        name = source.relative_to(ROOT / 'native').as_posix().replace('/', '_') + '.o'
        output = OBJECTS / name
        if not output.exists() or output.stat().st_mtime < max(source.stat().st_mtime, Path(__file__).stat().st_mtime, header_time):
            run([compiler, *flags, '-c', source, '-o', output])
        return output

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        objects = list(pool.map(compile_source, sources))
    if macos:
        run([compiler, '-dynamiclib', '-mmacosx-version-min=12.0', *objects,
             '-framework', 'Foundation', '-o', LIB / 'libf7zip.dylib', '-install_name', '@rpath/libf7zip.dylib'])
        run([compiler, '-std=c++17', '-O2', '-mmacosx-version-min=12.0',
             ROOT / 'native/f7zip_cli.mm', '-L' + str(LIB), '-lf7zip', '-framework', 'Foundation',
             '-Wl,-rpath,@executable_path', '-Wl,-rpath,@executable_path/../Frameworks/F7Zip',
             '-o', LIB / 'f7zip'])
    else:
        library_name = 'f7zip.dll' if windows else 'libf7zip.so'
        # 复用 7-Zip 自带的公开领域 SHA-256 实现。
        objects += [bundle / '_o' / name for name in ('Sha256.o', 'Sha256Opt.o', 'CpuArch.o')]
        link_flags = ['-Wl,--export-all-symbols', '-Wl,--out-implib,' + str(LIB / 'libf7zip.dll.a')] if windows else ['-Wl,-rpath,$ORIGIN']
        run([compiler, '-shared', *objects, *libraries, *link_flags, '-o', LIB / library_name])
        cli_objects = []
        if windows:
            resource = OBJECTS / 'cli.rc'
            resource.write_text('1 24 "' + (ROOT / 'windows/runner/runner.exe.manifest').as_posix() + '"\n')
            run(['windres', resource, '-o', OBJECTS / 'cli-resource.o'])
            cli_objects.append(OBJECTS / 'cli-resource.o')
        run([compiler, *flags, ROOT / 'native/f7zip_cli.cpp', *cli_objects, '-L' + str(LIB), '-lf7zip',
             *libraries, *([] if windows else ['-Wl,-rpath,$ORIGIN', '-Wl,-rpath,$ORIGIN/lib']),
             '-o', LIB / ('f7zip-cli.exe' if windows else 'f7zip-cli')])
    sfx_module = ROOT / 'native/sfx/7z-x86.sfx'
    if hashlib.sha256(sfx_module.read_bytes()).hexdigest() != '73af2700392aa92bc9342ae63844dfeed157d8d68bd356326a9bddb5e9e312d7':
        raise RuntimeError('Windows SFX 模块校验失败')
    shutil.copy2(sfx_module, LIB / sfx_module.name)
    licenses = LIB / 'licenses'
    licenses.mkdir(exist_ok=True)
    shutil.copy2(ENGINE / 'DOC/License.txt', licenses / '7zip.txt')
    shutil.copy2(ENGINE / 'DOC/copying.txt', licenses / 'LGPL-2.1.txt')
    shutil.copy2(BIT7Z / 'LICENSE', licenses / 'bit7z-MPL-2.0.txt')
    if not macos:
        prefix = Path(subprocess.check_output(['pkg-config', '--variable=prefix', 'icu-uc'], text=True).strip())
        for name, patterns in {
            'ICU': ['share/licenses/icu/LICENSE*', 'share/icu/*/LICENSE*', 'share/doc/libicu-dev/copyright'],
            'nlohmann-json': ['share/licenses/*json*/LICENSE*', 'share/doc/nlohmann-json3-dev/copyright'],
        }.items():
            matches = [path for pattern in patterns for path in prefix.glob(pattern) if path.is_file()]
            if not matches:
                raise RuntimeError(f'未找到 {name} 的分发许可证，请检查开发依赖是否完整安装')
            for index, path in enumerate(matches):
                shutil.copy2(path, licenses / f'{name}-{index + 1}.txt')
    if windows:
        bundle_windows_dependencies()
    print(f'7-Zip {ENGINE_VERSION} native libraries ready at {LIB}')


if __name__ == '__main__':
    main()
