#!/usr/bin/env python3
"""
テスト用ダミー環境 (test_env/) を生成するスクリプト。
Windowsアプリ（C++ / .NET混在想定）の製品フォルダ配下を模した構成を作成する。
"""

import os
import struct
import time
from datetime import datetime
from pathlib import Path


def align4(data: bytes) -> bytes:
    """4バイト境界にパディングする"""
    rem = len(data) % 4
    return data + (b"\x00" * (4 - rem) if rem else b"")


def build_vs_node(key: str, value: bytes, wtype: int, children: list[bytes], value_len_override: int | None = None) -> bytes:
    """Win32 VS_VERSION_INFO ツリーノードを構築する"""
    sz_key = key.encode("utf-16le") + b"\x00\x00"
    header_and_key = align4(struct.pack("<HHH", 0, 0, wtype) + sz_key)
    w_val_len = value_len_override if value_len_override is not None else len(value)
    body = header_and_key + value
    if children:
        body = align4(body)
        for idx, child in enumerate(children):
            body += child
            if idx < len(children) - 1:
                body = align4(body)
    w_len = len(body)
    # 先頭6バイト(wLength, wValueLength, wType)を上書き
    return struct.pack("<HHH", w_len, w_val_len, wtype) + body[6:]


def build_vs_string(key: str, val_str: str) -> bytes:
    """StringFileInfo 内の String エントリを構築する (wValueLength は文字数)"""
    val_bytes = val_str.encode("utf-16le") + b"\x00\x00"
    return build_vs_node(key, val_bytes, wtype=1, children=[], value_len_override=len(val_str) + 1)


def build_pe_dll_with_version(version_str: str, filename: str, description: str) -> bytes:
    """
    有効な PE ヘッダおよび .rsrc セクション (VS_VERSION_INFO) を持つ最小ダミー .dll を生成する。
    Windows の GetFileVersionInfo / PowerShell VersionInfo と Python PE パーサの双方で読み取り可能。
    """
    parts = [int(x) for x in version_str.split(".")]
    while len(parts) < 4:
        parts.append(0)
    major, minor, build, rev = parts[:4]

    file_ver_ms = (major << 16) | (minor & 0xFFFF)
    file_ver_ls = (build << 16) | (rev & 0xFFFF)

    # VS_FIXEDFILEINFO (52 bytes)
    fixed_info = struct.pack(
        "<13I",
        0xFEEF04BD,  # dwSignature
        0x00010000,  # dwStrucVersion
        file_ver_ms,  # dwFileVersionMS
        file_ver_ls,  # dwFileVersionLS
        file_ver_ms,  # dwProductVersionMS
        file_ver_ls,  # dwProductVersionLS
        0x0000003F,  # dwFileFlagsMask
        0x00000000,  # dwFileFlags
        0x00040004,  # dwFileOS (VOS_NT_WINDOWS32)
        0x00000002,  # dwFileType (VFT_DLL)
        0x00000000,  # dwFileSubtype
        0x00000000,  # dwFileDateMS
        0x00000000,  # dwFileDateLS
    )

    str_entries = [
        build_vs_string("FileDescription", description),
        build_vs_string("FileVersion", version_str),
        build_vs_string("InternalName", filename),
        build_vs_string("OriginalFilename", filename),
        build_vs_string("ProductName", description),
        build_vs_string("ProductVersion", version_str),
    ]
    string_table = build_vs_node("040904B0", b"", wtype=1, children=str_entries)
    string_file_info = build_vs_node("StringFileInfo", b"", wtype=1, children=[string_table])

    var_translation = build_vs_node("Translation", struct.pack("<HH", 0x0409, 0x04B0), wtype=0, children=[])
    var_file_info = build_vs_node("VarFileInfo", b"", wtype=1, children=[var_translation])

    vs_version_info = build_vs_node(
        "VS_VERSION_INFO",
        fixed_info,
        wtype=0,
        children=[string_file_info, var_file_info],
    )

    # .rsrc セクションの構築 (RVA = 0x1000)
    # Level 1: Type = RT_VERSION (16) -> offset 0x18
    dir_l1 = struct.pack("<IIHHHHII", 0, 0, 0, 0, 0, 1, 16, 0x80000018)
    # Level 2: Name/ID = 1 -> offset 0x30
    dir_l2 = struct.pack("<IIHHHHII", 0, 0, 0, 0, 0, 1, 1, 0x80000030)
    # Level 3: Lang = 1033 (0x0409) -> offset 0x48
    dir_l3 = struct.pack("<IIHHHHII", 0, 0, 0, 0, 0, 1, 0x0409, 0x00000048)
    # IMAGE_RESOURCE_DATA_ENTRY at offset 0x48 (points to RVA 0x1058)
    data_entry = struct.pack("<IIII", 0x1058, len(vs_version_info), 0, 0)

    rsrc_payload = dir_l1 + dir_l2 + dir_l3 + data_entry + vs_version_info
    rsrc_raw_size = ((len(rsrc_payload) + 0x1FF) // 0x200) * 0x200
    rsrc_section_data = rsrc_payload.ljust(rsrc_raw_size, b"\x00")

    # DOS Header (64 bytes, e_lfanew = 0x40)
    dos_header = bytearray(64)
    dos_header[0:2] = b"MZ"
    struct.pack_into("<I", dos_header, 0x3C, 0x40)

    # PE Signature + IMAGE_FILE_HEADER (24 bytes)
    pe_header = struct.pack(
        "<4sHHIIIHH",
        b"PE\x00\x00",
        0x014C,  # Machine (i386)
        1,       # NumberOfSections
        0x65000000,
        0,
        0,
        0x00E0,  # SizeOfOptionalHeader (224)
        0x2102,  # Characteristics (EXECUTABLE | 32BIT | DLL)
    )

    # IMAGE_OPTIONAL_HEADER32 (224 bytes)
    opt_header = bytearray(224)
    struct.pack_into("<H", opt_header, 0, 0x010B)       # Magic (PE32)
    struct.pack_into("<I", opt_header, 16, 0x00000000)  # AddressOfEntryPoint
    struct.pack_into("<I", opt_header, 28, 0x10000000)  # ImageBase
    struct.pack_into("<I", opt_header, 32, 0x00001000)  # SectionAlignment
    struct.pack_into("<I", opt_header, 36, 0x00000200)  # FileAlignment
    struct.pack_into("<H", opt_header, 40, 6)           # MajorOperatingSystemVersion
    struct.pack_into("<H", opt_header, 48, 6)           # MajorSubsystemVersion
    struct.pack_into("<I", opt_header, 56, 0x00002000)  # SizeOfImage
    struct.pack_into("<I", opt_header, 60, 0x00000200)  # SizeOfHeaders
    struct.pack_into("<H", opt_header, 68, 3)           # Subsystem (WINDOWS_CUI)
    struct.pack_into("<I", opt_header, 92, 16)          # NumberOfRvaAndSizes
    # DataDirectory[2] = Resource Table (offset 96 + 2*8 = 112)
    struct.pack_into("<II", opt_header, 112, 0x00001000, len(rsrc_payload))

    # IMAGE_SECTION_HEADER for .rsrc (40 bytes)
    sec_header = struct.pack(
        "<8sIIIIIIHHI",
        b".rsrc\x00\x00\x00",
        len(rsrc_payload),  # VirtualSize
        0x00001000,         # VirtualAddress
        rsrc_raw_size,      # SizeOfRawData
        0x00000200,         # PointerToRawData
        0,
        0,
        0,
        0,
        0x40000040,         # Characteristics (INITIALIZED_DATA | MEM_READ)
    )

    headers = (bytes(dos_header) + pe_header + bytes(opt_header) + sec_header).ljust(0x200, b"\x00")
    return headers + rsrc_section_data


def build_dummy_dll_without_version(name: str) -> bytes:
    """バージョンリソースを持たない最小ダミー .dll (フォールバック確認用)"""
    dos_header = bytearray(64)
    dos_header[0:2] = b"MZ"
    struct.pack_into("<I", dos_header, 0x3C, 0x40)
    pe_stub = b"PE\x00\x00" + f"DUMMY_DLL_NO_VERSION_RESOURCE:{name}".encode("ascii")
    return bytes(dos_header) + pe_stub.ljust(192, b"\x00")


def build_dummy_lib(name: str) -> bytes:
    """COFF Archive (!<arch>) 形式のダミー .lib を生成する"""
    content = f"DUMMY_STATIC_LIBRARY_OBJECT:{name}\n".encode("ascii")
    hdr = f"{name:<16}{'1700000000':<12}{'0':<6}{'0':<6}{'100644':<8}{len(content):<10}`\n".encode("ascii")
    return b"!<arch>\n" + hdr + content


def write_text(path: Path, content: str, encoding: str = "utf-8", mtime_str: str | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content.encode(encoding))
    if mtime_str:
        dt = datetime.strptime(mtime_str, "%Y-%m-%d %H:%M:%S")
        ts = time.mktime(dt.timetuple())
        os.utime(path, (ts, ts))


def write_bytes(path: Path, data: bytes, mtime_str: str | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    if mtime_str:
        dt = datetime.strptime(mtime_str, "%Y-%m-%d %H:%M:%S")
        ts = time.mktime(dt.timetuple())
        os.utime(path, (ts, ts))


def create_test_env(base_dir: Path) -> None:
    test_env = base_dir / "test_env"

    # =========================================================================
    # ProductA の作成
    # =========================================================================
    prod_a = test_env / "ProductA"

    # 1. ImageEngine.dll / ImageEngine.lib / ImageEngine.h
    #    - ImageEngine.dll はバイナリ情報 (4.5.2.0) を保持 → 最優先で 4.5.2.0 が抽出される
    #    - ImageEngine.h には #define IMAGE_ENGINE_VERSION "4.0.0" があり、
    #      .dll ではバイナリ情報が #define より優先されることを検証、
    #      .lib では #define の 4.0.0 が抽出されることを検証
    write_bytes(
        prod_a / "bin" / "ImageEngine.dll",
        build_pe_dll_with_version("4.5.2.0", "ImageEngine.dll", "High-Speed Image Processing Engine"),
        mtime_str="2024-03-10 09:00:00",
    )
    write_bytes(
        prod_a / "lib" / "ImageEngine.lib",
        build_dummy_lib("ImageEngine.lib"),
        mtime_str="2024-03-10 09:00:00",
    )
    write_text(
        prod_a / "include" / "ImageEngine.h",
        """#pragma once
// ImageEngine Header File
// DLLバイナリ側のバージョン(4.5.2.0)が優先されることを確認するためのヘッダ定義
// #define IMAGE_ENGINE_VERSION "3.9.0-rc"
#define IMAGE_ENGINE_VERSION "4.0.0"

namespace ImageEngine {
    void Initialize();
}
""",
        mtime_str="2024-03-10 09:00:00",
    )

    # 2. Pattern (d): 親フォルダ名にバージョン表記 (ThirdParty_v2.4.1)
    #    - thirdparty_math.lib / thirdparty_math.dll (バイナリバージョン無し) / thirdparty_math.h
    #    - ヘッダ内に #define THIRDPARTY_MATH_VERSION "2.0.0" があっても、
    #      優先順位「フォルダ名 ＞ #define」により 2.4.1 が抽出されることを検証
    tp_dir = prod_a / "ext" / "ThirdParty_v2.4.1"
    write_bytes(
        tp_dir / "lib" / "thirdparty_math.lib",
        build_dummy_lib("thirdparty_math.lib"),
        mtime_str="2024-04-01 12:00:00",
    )
    write_bytes(
        tp_dir / "bin" / "thirdparty_math.dll",
        build_dummy_dll_without_version("thirdparty_math.dll"),
        mtime_str="2024-04-01 12:00:00",
    )
    write_text(
        tp_dir / "include" / "thirdparty_math.h",
        """#pragma once
/*
 * thirdparty_math.h
 * 親フォルダ名 (ThirdParty_v2.4.1) が #define より優先されることを確認するテスト用ヘッダ
 */
#define THIRDPARTY_MATH_VERSION "2.0.0"

double calc_vector_norm(double x, double y, double z);
""",
        mtime_str="2024-04-01 12:00:00",
    )

    # 3. Pattern (a): #define で定義（コメントアウトされたダミー定義も含む）
    #    - algocore.lib / algocore.h
    write_bytes(
        prod_a / "lib" / "algocore.lib",
        build_dummy_lib("algocore.lib"),
        mtime_str="2024-05-20 15:30:00",
    )
    write_text(
        prod_a / "include" / "algocore.h",
        """#pragma once
/*
 * AlgoCore Library Header
 *
 * 過去の定義（ブロックコメント内のダミー定義）:
 * #define ALGOCORE_VERSION "0.8.0"
 * #define ALGOCORE_VERSION "1.1.0-alpha"
 *
 * 改訂履歴コメントよりも #define が優先されることも同時に確認:
 * 2023/01/15 Ver.1.0.0 初版
 */

// 行コメントでコメントアウトされたダミー定義:
// #define ALGOCORE_VERSION "1.5.0-dummy"
   // #define ALGOCORE_VER "1.7.9"

// 有効なバージョン定義:
#define ALGOCORE_VERSION "1.8.3"

int AlgoCore_Execute(int mode);
""",
        mtime_str="2024-05-20 15:30:00",
    )

    # 4. Pattern (b): 改訂履歴コメント（上が最新の降順パターン）
    #    - netclient.lib / netclient.h
    write_bytes(
        prod_a / "lib" / "netclient.lib",
        build_dummy_lib("netclient.lib"),
        mtime_str="2024-06-10 11:00:00",
    )
    write_text(
        prod_a / "include" / "netclient.h",
        """#pragma once
/*==============================================================================
 * File Name   : netclient.h
 * Description : ネットワーク通信クライアントライブラリ
 *
 * 改訂履歴 (Revision History - 降順: 上が最新)
 * -----------------------------------------------------------------------------
 * 日付         バージョン   担当者   変更内容
 * 2025/10/15   Ver.3.4.0    山田     TLS 1.3 ハンドシェイク対応
 * 2024/06/20   Ver.3.3.1    佐藤     再接続タイムアウト処理の不具合修正
 * 2023/11/05   Ver.3.2.0    鈴木     IPv6 デュアルスタック対応
 * 2022/04/01   Ver.3.0.0    高橋     初版リリース
 *============================================================================*/

namespace NetClient {
    bool Connect(const char* endpoint, int port);
}
""",
        mtime_str="2024-06-10 11:00:00",
    )

    # 5. ProjectReference 用サブプロジェクト: CommonLogger
    #    - ProductA.vcxproj から ProjectReference で参照される
    #    - MAJOR / MINOR / PATCH 分割型の #define (コメントアウトされたダミー定義付き)
    common_dir = prod_a / "CommonLogger"
    write_bytes(
        common_dir / "lib" / "CommonLogger.lib",
        build_dummy_lib("CommonLogger.lib"),
        mtime_str="2024-07-05 16:45:00",
    )
    write_text(
        common_dir / "include" / "CommonLogger.h",
        """#pragma once
// CommonLogger.h - ProjectReference 経由で参照される共通ロガー
// #define COMMON_LOGGER_VERSION_MAJOR 1
/* #define COMMON_LOGGER_VERSION "0.5.0" */
#define COMMON_LOGGER_VERSION_MAJOR 2
#define COMMON_LOGGER_VERSION_MINOR 1
#define COMMON_LOGGER_VERSION_PATCH 4

void LogInfo(const char* msg);
""",
        mtime_str="2024-07-05 16:45:00",
    )
    write_text(
        common_dir / "CommonLogger.vcxproj",
        """<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup Label="Globals">
    <ProjectGuid>{A1111111-2222-3333-4444-555555555555}</ProjectGuid>
    <RootNamespace>CommonLogger</RootNamespace>
  </PropertyGroup>
  <PropertyGroup Condition="'$(Configuration)|$(Platform)'=='Release|x64'" Label="Configuration">
    <ConfigurationType>StaticLibrary</ConfigurationType>
    <OutDir>$(ProjectDir)lib\\</OutDir>
    <TargetName>CommonLogger</TargetName>
    <TargetExt>.lib</TargetExt>
  </PropertyGroup>
  <ItemDefinitionGroup Condition="'$(Configuration)|$(Platform)'=='Release|x64'">
    <ClCompile>
      <AdditionalIncludeDirectories>$(ProjectDir)include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ClCompile>
  </ItemDefinitionGroup>
  <ItemGroup>
    <ClInclude Include="include\\CommonLogger.h" />
  </ItemGroup>
</Project>
""",
        mtime_str="2024-07-05 16:45:00",
    )

    # ProductA.vcxproj (AdditionalDependencies, ProjectReference, AdditionalIncludeDirectories を含む)
    write_text(
        prod_a / "ProductA.vcxproj",
        """<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup Label="Globals">
    <ProjectGuid>{11111111-AAAA-BBBB-CCCC-000000000001}</ProjectGuid>
    <RootNamespace>ProductA</RootNamespace>
    <TargetFrameworkVersion>v4.8</TargetFrameworkVersion>
  </PropertyGroup>
  <ItemDefinitionGroup Condition="'$(Configuration)|$(Platform)'=='Release|x64'">
    <ClCompile>
      <AdditionalIncludeDirectories>include;ext\\ThirdParty_v2.4.1\\include;CommonLogger\\include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ClCompile>
    <Link>
      <AdditionalLibraryDirectories>lib;ext\\ThirdParty_v2.4.1\\lib;CommonLogger\\lib;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
      <AdditionalDependencies>algocore.lib;netclient.lib;thirdparty_math.lib;ImageEngine.lib;kernel32.lib;user32.lib;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
  <ItemGroup>
    <ProjectReference Include="CommonLogger\\CommonLogger.vcxproj">
      <Project>{A1111111-2222-3333-4444-555555555555}</Project>
    </ProjectReference>
  </ItemGroup>
</Project>
""",
        mtime_str="2024-07-10 10:00:00",
    )

    # ProductA の link.read.1.tlog / CL.read.1.tlog (MSBuild 標準の UTF-16LE 形式)
    write_text(
        prod_a / "x64" / "Release" / "ProductA.tlog" / "link.read.1.tlog",
        """^C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\X64\\RELEASE\\MAIN.OBJ
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\LIB\\ALGOCORE.LIB
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\LIB\\NETCLIENT.LIB
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\EXT\\THIRDPARTY_V2.4.1\\LIB\\THIRDPARTY_MATH.LIB
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\LIB\\IMAGEENGINE.LIB
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\COMMONLOGGER\\LIB\\COMMONLOGGER.LIB
C:\\PROGRAM FILES (X86)\\WINDOWS KITS\\10\\LIB\\10.0.22621.0\\UM\\X64\\KERNEL32.LIB
C:\\PROGRAM FILES (X86)\\WINDOWS KITS\\10\\LIB\\10.0.22621.0\\UM\\X64\\USER32.LIB
""",
        encoding="utf-16",
        mtime_str="2024-07-10 10:05:00",
    )
    write_text(
        prod_a / "x64" / "Release" / "ProductA.tlog" / "CL.read.1.tlog",
        """^C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\SRC\\MAIN.CPP
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\INCLUDE\\ALGOCORE.H
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\INCLUDE\\NETCLIENT.H
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\EXT\\THIRDPARTY_V2.4.1\\INCLUDE\\THIRDPARTY_MATH.H
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\INCLUDE\\IMAGEENGINE.H
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\COMMONLOGGER\\INCLUDE\\COMMONLOGGER.H
C:\\PROGRAM FILES (X86)\\WINDOWS KITS\\10\\INCLUDE\\10.0.22621.0\\UM\\WINDOWS.H
""",
        encoding="utf-16",
        mtime_str="2024-07-10 10:05:00",
    )

    # =========================================================================
    # ProductB の作成
    # =========================================================================
    prod_b = test_env / "ProductB"

    # 1. DotNetAnalytics.dll (.NET / C++混在想定のマネージド/ネイティブDLL、バイナリバージョン 5.12.0.104)
    write_bytes(
        prod_b / "bin" / "DotNetAnalytics.dll",
        build_pe_dll_with_version("5.12.0.104", "DotNetAnalytics.dll", ".NET Analytics Assembly"),
        mtime_str="2024-08-01 10:00:00",
    )

    # 2. Pattern (c): 改訂履歴コメント（下が最新の昇順パターン）
    #    - serialcomm.lib / serialcomm.h
    write_bytes(
        prod_b / "lib" / "serialcomm.lib",
        build_dummy_lib("serialcomm.lib"),
        mtime_str="2024-08-10 13:15:00",
    )
    write_text(
        prod_b / "include" / "serialcomm.h",
        """#pragma once
/*------------------------------------------------------------------------------
 * serialcomm.h - シリアルポート通信制御ライブラリ
 *
 * [改訂履歴] (昇順: 下が最新)
 * No.  Date        Version   Author   Description
 * 01   2021-05-10  v1.0.0    Kato     初版作成
 * 02   2022-08-22  v1.1.0    Kato     高ボーレート(921600bps)対応
 * 03   2024-02-14  v1.2.3    Yoshida  受信バッファオーバーラン対策
 * 04   2025-07-01  v1.3.0    Yoshida  非同期読み取りAPIの追加
 *----------------------------------------------------------------------------*/

int SerialComm_Open(int comPort, int baudRate);
""",
        mtime_str="2024-08-10 13:15:00",
    )

    # 3. 改訂履歴コメント（昇順・降順が判別できないパターン → 先頭と末尾を両方出力＋要目視確認）
    #    - legacy_parser.lib / legacy_parser.h
    write_bytes(
        prod_b / "lib" / "legacy_parser.lib",
        build_dummy_lib("legacy_parser.lib"),
        mtime_str="2024-08-20 17:00:00",
    )
    write_text(
        prod_b / "include" / "legacy_parser.h",
        """#pragma once
/*------------------------------------------------------------------------------
 * legacy_parser.h - 旧式データフォーマットパーサ
 *
 * [改訂履歴] (日付なし・バージョン番号も非単調のため昇順/降順が判別不能なケース)
 *   Rev 2.1.0  XML名前空間の暫定対応パッチ
 *   Rev 2.4.0  メモリ使用量削減およびキャッシュ調整
 *   Rev 1.9.2  Shift-JIS エンコーディング分岐の差し戻し修正
 *----------------------------------------------------------------------------*/

bool ParseLegacyData(const char* buffer, int length);
""",
        mtime_str="2024-08-20 17:00:00",
    )

    # 4. Pattern (e): バージョン記載なし（タイムスタンプフォールバック確認用）
    #    - rawdevice.lib / rawdevice.h (更新日時: 2024-09-15 14:20:00)
    write_bytes(
        prod_b / "lib" / "rawdevice.lib",
        build_dummy_lib("rawdevice.lib"),
        mtime_str="2024-09-15 14:20:00",
    )
    write_text(
        prod_b / "include" / "rawdevice.h",
        """#pragma once
/*
 * rawdevice.h - デバイス直接制御ユーティリティ
 * ※ 本ファイルにはバージョン定義(#define)や改訂履歴コメントが存在しない
 */

int RawDevice_Control(unsigned int ioctlCode, void* inBuf, unsigned int inSize);
""",
        mtime_str="2024-09-15 14:20:00",
    )

    # ProductB.vcxproj (AdditionalDependencies, ProjectReference, AdditionalIncludeDirectories, Reference を含む)
    write_text(
        prod_b / "ProductB.vcxproj",
        """<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup Label="Globals">
    <ProjectGuid>{22222222-AAAA-BBBB-CCCC-000000000002}</ProjectGuid>
    <RootNamespace>ProductB</RootNamespace>
    <TargetFrameworkVersion>v4.8</TargetFrameworkVersion>
  </PropertyGroup>
  <ItemDefinitionGroup Condition="'$(Configuration)|$(Platform)'=='Release|x64'">
    <ClCompile>
      <AdditionalIncludeDirectories>include;..\\ProductA\\CommonLogger\\include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ClCompile>
    <Link>
      <AdditionalLibraryDirectories>lib;..\\ProductA\\CommonLogger\\lib;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
      <AdditionalDependencies>serialcomm.lib;legacy_parser.lib;rawdevice.lib;advapi32.lib;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
  <ItemGroup>
    <Reference Include="DotNetAnalytics">
      <HintPath>bin\\DotNetAnalytics.dll</HintPath>
    </Reference>
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\\ProductA\\CommonLogger\\CommonLogger.vcxproj">
      <Project>{A1111111-2222-3333-4444-555555555555}</Project>
    </ProjectReference>
  </ItemGroup>
</Project>
""",
        mtime_str="2024-09-20 09:30:00",
    )

    # ProductB の link.read.1.tlog / CL.read.1.tlog
    write_text(
        prod_b / "x64" / "Release" / "ProductB.tlog" / "link.read.1.tlog",
        """^C:\\WORKSPACE\\TEST_ENV\\PRODUCTB\\X64\\RELEASE\\APP.OBJ
C:\\WORKSPACE\\TEST_ENV\\PRODUCTB\\LIB\\SERIALCOMM.LIB
C:\\WORKSPACE\\TEST_ENV\\PRODUCTB\\LIB\\LEGACY_PARSER.LIB
C:\\WORKSPACE\\TEST_ENV\\PRODUCTB\\LIB\\RAWDEVICE.LIB
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\COMMONLOGGER\\LIB\\COMMONLOGGER.LIB
C:\\PROGRAM FILES (X86)\\WINDOWS KITS\\10\\LIB\\10.0.22621.0\\UM\\X64\\ADVAPI32.LIB
""",
        encoding="utf-16",
        mtime_str="2024-09-20 09:35:00",
    )
    write_text(
        prod_b / "x64" / "Release" / "ProductB.tlog" / "CL.read.1.tlog",
        """^C:\\WORKSPACE\\TEST_ENV\\PRODUCTB\\SRC\\APP.CPP
C:\\WORKSPACE\\TEST_ENV\\PRODUCTB\\INCLUDE\\SERIALCOMM.H
C:\\WORKSPACE\\TEST_ENV\\PRODUCTB\\INCLUDE\\LEGACY_PARSER.H
C:\\WORKSPACE\\TEST_ENV\\PRODUCTB\\INCLUDE\\RAWDEVICE.H
C:\\WORKSPACE\\TEST_ENV\\PRODUCTA\\COMMONLOGGER\\INCLUDE\\COMMONLOGGER.H
""",
        encoding="utf-16",
        mtime_str="2024-09-20 09:35:00",
    )


if __name__ == "__main__":
    repo_root = Path(__file__).resolve().parent
    create_test_env(repo_root)
    print(f"Created dummy test environment under: {repo_root / 'test_env'}")
