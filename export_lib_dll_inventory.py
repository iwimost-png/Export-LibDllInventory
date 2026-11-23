#!/usr/bin/env python3
"""
export_lib_dll_inventory.py

Windowsアプリ（C++ / .NET混在想定）の製品フォルダ配下から、依存している .lib / .dll と
各バージョンをルールベース（正規表現＋メタデータのみ、AI不使用）で抽出して
UTF-8 (BOM付き) CSV に出力するツール。

【優先順位】
  1. バイナリ情報 (.dll の PE VS_VERSION_INFO リソース)
  2. フォルダ名 (例: ThirdParty_v2.4.1)
  3. ヘッダファイル (.h) の #define (コメントアウトされたダミー定義は除外)
  4. ヘッダファイル (.h) の改訂履歴コメント (降順 / 昇順 を自動判別、判別不能時は先頭と末尾を両方出力し「要目視確認」)
  5. ファイルの更新日時 (タイムスタンプフォールバック)
"""

from __future__ import annotations

import argparse
import csv
import re
import struct
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path


# Windows OS / Visual Studio 標準システムライブラリ（抽出対象外）
SYSTEM_LIBS = {
    "kernel32.lib",
    "user32.lib",
    "gdi32.lib",
    "winspool.lib",
    "comdlg32.lib",
    "advapi32.lib",
    "shell32.lib",
    "ole32.lib",
    "oleaut32.lib",
    "uuid.lib",
    "odbc32.lib",
    "odbccp32.lib",
    "ws2_32.lib",
    "msvcrt.lib",
    "msvcrtd.lib",
    "ucrt.lib",
    "vcruntime.lib",
    "bcrypt.lib",
    "crypt32.lib",
}

# フォルダ名からバージョンを抽出する際に無視する一般的なディレクトリ名
IGNORED_DIR_NAMES = {
    "bin",
    "lib",
    "libs",
    "include",
    "inc",
    "src",
    "ext",
    "thirdparty",
    "x64",
    "x86",
    "win32",
    "arm64",
    "debug",
    "release",
}


@dataclass
class RevisionEntry:
    version: str
    date_tuple: tuple[int, int, int] | None
    raw_date: str | None
    raw_line: str


@dataclass
class DependencyRecord:
    product: str
    file_path: Path
    file_name: str
    file_type: str
    relative_path: str
    detected_in: list[str] = field(default_factory=list)
    header_path: Path | None = None
    version: str = ""
    version_source: str = ""
    status: str = "OK"
    notes: str = ""


def read_text_auto_encoding(path: Path) -> str:
    """BOMやエンコーディング(UTF-16LE/BE, UTF-8-SIG, UTF-8, CP932)を自動判別してテキストを読み込む"""
    raw = path.read_bytes()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        return raw.decode("utf-16", errors="replace")
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw.decode("utf-8-sig", errors="replace")
    # NULLバイトが多く含まれる場合は UTF-16LE とみなす (.tlog 等)
    if b"\x00" in raw[:100]:
        return raw.decode("utf-16le", errors="replace")
    for enc in ("utf-8", "cp932", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


# =============================================================================
# 1. バイナリ情報 (.dll) からのバージョン抽出
# =============================================================================
def extract_dll_binary_version(dll_path: Path) -> tuple[str | None, str]:
    """
    PE (.dll) バイナリの VS_VERSION_INFO リソースからバージョンを抽出する。
    Windows / Linux 双方で動作するよう、PE バイナリ構造を直接解析する。
    """
    try:
        data = dll_path.read_bytes()
    except OSError:
        return None, ""

    if len(data) < 64 or data[:2] != b"MZ":
        return None, ""

    # 1) StringFileInfo 内の UTF-16LE "FileVersion" または "ProductVersion" を検索
    for key_name in ("FileVersion", "ProductVersion"):
        key_bytes = key_name.encode("utf-16le") + b"\x00\x00"
        pos = 0
        while True:
            idx = data.find(key_bytes, pos)
            if idx == -1:
                break
            val_start = idx + len(key_bytes)
            # Win32 String 構造体ではキー直後が 4バイト境界にパディングされる
            while val_start < len(data) and (val_start % 2 != 0 or data[val_start : val_start + 2] == b"\x00\x00"):
                # パディング用の 0x0000 は最大2バイト分スキップ
                if val_start - (idx + len(key_bytes)) >= 4:
                    break
                val_start += 2
            # UTF-16LE の終端 NULL まで取得
            end = val_start
            while end + 1 < len(data):
                if data[end] == 0 and data[end + 1] == 0:
                    break
                end += 2
            if end > val_start:
                candidate = data[val_start:end].decode("utf-16le", errors="ignore").strip()
                m = re.search(r"\d+\.\d+(?:\.\d+){0,2}", candidate)
                if m and m.group(0) != "0.0.0.0":
                    return m.group(0), f"PE Resource ({key_name})"
            pos = idx + 2

    # 2) VS_FIXEDFILEINFO シグネチャ (0xFEEF04BD) を検索
    sig = struct.pack("<I", 0xFEEF04BD)
    idx = data.find(sig)
    if idx != -1 and idx + 24 <= len(data):
        _, struc_ver, file_ms, file_ls, prod_ms, prod_ls = struct.unpack_from("<6I", data, idx)
        if struc_ver == 0x00010000:
            major = (file_ms >> 16) & 0xFFFF
            minor = file_ms & 0xFFFF
            build = (file_ls >> 16) & 0xFFFF
            rev = file_ls & 0xFFFF
            ver_str = f"{major}.{minor}.{build}.{rev}"
            if ver_str != "0.0.0.0":
                return ver_str, "PE Resource (VS_FIXEDFILEINFO)"
            p_major = (prod_ms >> 16) & 0xFFFF
            p_minor = prod_ms & 0xFFFF
            p_build = (prod_ls >> 16) & 0xFFFF
            p_rev = prod_ls & 0xFFFF
            p_ver_str = f"{p_major}.{p_minor}.{p_build}.{p_rev}"
            if p_ver_str != "0.0.0.0":
                return p_ver_str, "PE Resource (VS_FIXEDFILEINFO ProductVersion)"

    return None, ""


# =============================================================================
# 2. 親フォルダ名からのバージョン抽出
# =============================================================================
FOLDER_VERSION_PATTERNS = [
    # 例: ThirdParty_v2.4.1, LibFoo-ver1.2.3, SDK_v3.0
    re.compile(r"(?i)(?:^|[_\-\s.])(?:ver\.?|version\.?|rev\.?|v)(\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z._-]+)?)(?:$|[_\-\s])"),
    # 例: ThirdParty_2.4.1, Boost-1.82.0
    re.compile(r"(?:^|[_\-\s])(\d+\.\d+(?:\.\d+){1,2}(?:-[0-9A-Za-z._-]+)?)$"),
]


def extract_folder_version(file_path: Path, header_path: Path | None, stop_dir: Path) -> tuple[str | None, str]:
    """
    対象ファイル（および対応ヘッダ）の親フォルダ名を辿り、フォルダ名に含まれるバージョン表記を抽出する。
    """
    candidates: list[Path] = []
    for target in (file_path, header_path):
        if target is None:
            continue
        cur = target.resolve().parent
        stop_resolved = stop_dir.resolve()
        while cur != stop_resolved and stop_resolved in cur.parents:
            if cur not in candidates:
                candidates.append(cur)
            cur = cur.parent

    for folder in candidates:
        name = folder.name
        if name.lower() in IGNORED_DIR_NAMES or name.lower().endswith(".tlog"):
            continue
        for pat in FOLDER_VERSION_PATTERNS:
            m = pat.search(name)
            if m:
                return m.group(1), f"フォルダ '{name}'"

    return None, ""


# =============================================================================
# 3. ヘッダファイル (.h) の #define からのバージョン抽出
# =============================================================================
def strip_c_comments(code: str) -> str:
    """
    C/C++ コードからブロックコメント (/* ... */) と行コメント (// ...) を除去する。
    文字列リテラル内の // や /* は保持し、コメントアウトされたダミー #define を確実に除外する。
    """
    pattern = re.compile(
        r'//.*?$|/\*.*?\*/|"(?:\\.|[^\\"])*"|\'(?:\\.|[^\\\'])*\'',
        re.DOTALL | re.MULTILINE,
    )

    def replacer(match: re.Match[str]) -> str:
        s = match.group(0)
        if s.startswith("/"):
            return ""
        return s

    return pattern.sub(replacer, code)


DEFINE_SINGLE_REGEX = re.compile(
    r'^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*(?:VERSION|VER|REV|RELEASE)[A-Za-z0-9_]*)\s+'
    r'["\']?[vV]?(\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z._-]+)?)["\']?\s*$',
    re.IGNORECASE | re.MULTILINE,
)

DEFINE_COMPONENT_REGEX = re.compile(
    r"^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*?)_(MAJOR|MINOR|PATCH|BUILD|REVISION|REV|SUB)\s+"
    r'["\']?(\d+)["\']?\s*$',
    re.IGNORECASE | re.MULTILINE,
)


def extract_define_version(header_path: Path) -> tuple[str | None, str]:
    """
    コメントを除去した上で有効な #define からバージョンを抽出する。
    単一文字列マクロ (#define FOO_VERSION "1.2.3") と
    分割マクロ (#define FOO_VERSION_MAJOR 1 / MINOR 2 / PATCH 3) の両方に対応。
    """
    text = read_text_auto_encoding(header_path)
    active_code = strip_c_comments(text)

    # 1) 単一 #define マクロ
    m = DEFINE_SINGLE_REGEX.search(active_code)
    if m:
        macro_name, ver = m.group(1), m.group(2)
        return ver, f"#define {macro_name}"

    # 2) MAJOR / MINOR / PATCH 分割マクロ
    components: dict[str, dict[str, str]] = {}
    for cm in DEFINE_COMPONENT_REGEX.finditer(active_code):
        prefix = cm.group(1)
        part = cm.group(2).upper()
        val = cm.group(3)
        components.setdefault(prefix, {})[part] = val

    for prefix, parts in components.items():
        if "MAJOR" in parts and "MINOR" in parts:
            ver_parts = [parts["MAJOR"], parts["MINOR"]]
            for third_key in ("PATCH", "BUILD", "REVISION", "REV", "SUB"):
                if third_key in parts:
                    ver_parts.append(parts[third_key])
                    break
            return ".".join(ver_parts), f"#define {prefix}_MAJOR/MINOR/..."

    return None, ""


# =============================================================================
# 4. ヘッダファイル (.h) の改訂履歴コメントからのバージョン抽出
# =============================================================================
COMMENT_BLOCK_REGEX = re.compile(r"/\*.*?\*/|(?:^\s*//[^\r\n]*\r?\n?)+", re.DOTALL | re.MULTILINE)

DATE_REGEX = re.compile(r"\b(19\d\d|20\d\d)[/\-.](0?[1-9]|1[0-2])[/\-.](0?[1-9]|[12]\d|3[01])\b")

EXPLICIT_VER_REGEX = re.compile(
    r"(?i)(?:ver\.?|version|rev\.?|v)\s*[:.]?\s*(\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z._-]+)?)\b"
)

BARE_VER_REGEX = re.compile(r"(?<![0-9/.\-])(\d+\.\d+(?:\.\d+){1,2})(?![0-9/.\-])")

HISTORY_HEADER_KEYWORDS = re.compile(
    r"(?i)(?:改訂履歴|更新履歴|変更履歴|履歴|revision\s*history|update\s*history|change\s*log|history)"
)


def parse_version_tuple(ver_str: str) -> tuple[int, ...]:
    nums = re.findall(r"\d+", ver_str)
    return tuple(int(n) for n in nums) if nums else (0,)


def extract_revision_history_version(header_path: Path) -> tuple[str | None, str, str, str]:
    """
    ヘッダファイルのコメントから改訂履歴を抽出し、昇順・降順を判別する。
    戻り値: (version_str, version_source, status, notes)
    """
    text = read_text_auto_encoding(header_path)
    comment_blocks = COMMENT_BLOCK_REGEX.findall(text)

    entries: list[RevisionEntry] = []

    for block in comment_blocks:
        has_history_keyword = bool(HISTORY_HEADER_KEYWORDS.search(block))
        block_entries: list[RevisionEntry] = []

        for raw_line in block.splitlines():
            # コメント記号を除去
            line = re.sub(r"^\s*(?:/\*+|\*+/|\*+|//+)\s*", "", raw_line).strip()
            if not line:
                continue
            # コメントアウトされた #define / #include 等のプリプロセッサ行は除外
            if re.match(r"^#\s*(?:define|include|pragma|if|ifdef|ifndef|endif|undef)\b", line):
                continue

            date_match = DATE_REGEX.search(line)
            if date_match:
                y, m, d = int(date_match.group(1)), int(date_match.group(2)), int(date_match.group(3))
                date_str = date_match.group(0)
                # 日付部分を除いた残りの文字列からバージョンを探す
                line_without_date = line[: date_match.start()] + " " + line[date_match.end() :]
                ver_match = EXPLICIT_VER_REGEX.search(line_without_date) or BARE_VER_REGEX.search(line_without_date)
                if ver_match:
                    block_entries.append(
                        RevisionEntry(
                            version=ver_match.group(1),
                            date_tuple=(y, m, d),
                            raw_date=date_str,
                            raw_line=line,
                        )
                    )
            elif has_history_keyword:
                # 改訂履歴セクション内で日付が無い行 (例: "Rev 2.1.0  XML名前空間の暫定対応")
                ver_match = EXPLICIT_VER_REGEX.search(line)
                if ver_match:
                    block_entries.append(
                        RevisionEntry(
                            version=ver_match.group(1),
                            date_tuple=None,
                            raw_date=None,
                            raw_line=line,
                        )
                    )

        if block_entries:
            entries.extend(block_entries)

    if not entries:
        return None, "", "OK", ""

    if len(entries) == 1:
        e = entries[0]
        return e.version, "改訂履歴コメント", "OK", f"履歴1件 ({e.version})"

    # 複数履歴がある場合の昇順・降順判定
    all_have_dates = all(e.date_tuple is not None for e in entries)
    vers = [parse_version_tuple(e.version) for e in entries]

    if all_have_dates:
        dates = [e.date_tuple for e in entries if e.date_tuple is not None]
        dates_asc = all(dates[i] <= dates[i + 1] for i in range(len(dates) - 1)) and dates[0] < dates[-1]
        dates_desc = all(dates[i] >= dates[i + 1] for i in range(len(dates) - 1)) and dates[0] > dates[-1]
        vers_non_decreasing = all(vers[i] <= vers[i + 1] for i in range(len(vers) - 1))
        vers_non_increasing = all(vers[i] >= vers[i + 1] for i in range(len(vers) - 1))

        if dates_asc and vers_non_decreasing:
            latest = entries[-1]
            return (
                latest.version,
                "改訂履歴コメント(昇順)",
                "OK",
                f"全{len(entries)}件: 先頭={entries[0].version}({entries[0].raw_date}) -> 末尾(最新)={latest.version}({latest.raw_date})",
            )
        if dates_desc and vers_non_increasing:
            latest = entries[0]
            return (
                latest.version,
                "改訂履歴コメント(降順)",
                "OK",
                f"全{len(entries)}件: 先頭(最新)={latest.version}({latest.raw_date}) <- 末尾={entries[-1].version}({entries[-1].raw_date})",
            )

    # 昇順・降順が判別できない場合は「先頭と末尾」を両方出力し、Status列に「要目視確認」を立てる
    first_ver = entries[0].version
    last_ver = entries[-1].version
    combined_ver = f"先頭: {first_ver} / 末尾: {last_ver}"
    return (
        combined_ver,
        "改訂履歴コメント(順序不明)",
        "要目視確認",
        f"全{len(entries)}件の履歴の昇順・降順が判別不能なため先頭と末尾を出力",
    )


# =============================================================================
# 5. タイムスタンプ（更新日時）フォールバック
# =============================================================================
def extract_timestamp_version(file_path: Path) -> tuple[str, str]:
    mtime = file_path.stat().st_mtime
    dt_str = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
    return dt_str, f"{file_path.name} の更新日時"


# =============================================================================
# プロジェクト (.vcxproj) / ビルドログ (.tlog) / ディレクトリ解析
# =============================================================================
def build_case_insensitive_file_index(root_dir: Path) -> dict[str, list[Path]]:
    """
    Windows の大文字パス (.tlog 内など) や相対パスから実ファイルを高速に解決するためのインデックスを作成
    """
    index: dict[str, list[Path]] = {}
    for p in root_dir.rglob("*"):
        if p.is_file():
            index.setdefault(p.name.lower(), []).append(p.resolve())
    return index


def resolve_windows_or_relative_path(
    raw_path_str: str,
    base_dir: Path,
    root_dir: Path,
    file_index: dict[str, list[Path]],
) -> Path | None:
    """
    .vcxproj や .tlog に記載された Windows パス (C:\\... や ..\\...) をワークスペース内の実ファイルに解決する
    """
    cleaned = raw_path_str.strip().strip('"').replace("$(ProjectDir)", "")
    if not cleaned or cleaned.startswith("%("):
        return None

    norm = cleaned.replace("\\", "/")
    basename_lower = Path(norm).name.lower()
    if basename_lower in SYSTEM_LIBS:
        return None
    if "program files" in norm.lower() or "/windows kits/" in norm.lower() or "c:/windows/" in norm.lower():
        return None

    # 1) base_dir からの相対パスとして直接存在するか確認
    direct_candidate = (base_dir / norm).resolve()
    if direct_candidate.is_file():
        return direct_candidate

    # 2) 파일名インデックスからパス末尾一致（大文字小文字無視）で照合
    candidates = file_index.get(basename_lower, [])
    if not candidates:
        return None
    if len(candidates) == 1:
        return candidates[0]

    norm_parts = [part.lower() for part in Path(norm).parts if part not in ("/", "\\", ".") and ":" not in part]
    best_match: Path | None = None
    best_score = -1

    for cand in candidates:
        cand_parts = [p.lower() for p in cand.parts]
        # 末尾から何階層一致するかスコア計算
        score = 0
        for a, b in zip(reversed(norm_parts), reversed(cand_parts)):
            if a == b:
                score += 1
            else:
                break
        # 同じ製品フォルダ配下であれば優先度を上げる
        if base_dir.resolve() in cand.parents:
            score += 0.5
        if score > best_score:
            best_score = score
            best_match = cand

    return best_match


def parse_vcxproj(
    vcxproj_path: Path,
    product_dir: Path,
    root_dir: Path,
    file_index: dict[str, list[Path]],
) -> tuple[list[tuple[Path, str]], list[Path], list[Path]]:
    """
    .vcxproj を解析し、以下を返す:
      - 検出された (.lib / .dll の Path, 検出元ラベル) のリスト
      - AdditionalIncludeDirectories のディレクトリリスト
      - ClInclude で明示された .h ファイルリスト
    """
    xml_text = read_text_auto_encoding(vcxproj_path)
    root = ET.fromstring(xml_text)
    proj_dir = vcxproj_path.parent

    # 名前空間を除去してタグ名だけで検索できるようにする
    def local_tag(elem: ET.Element) -> str:
        return elem.tag.split("}", 1)[-1] if "}" in elem.tag else elem.tag

    lib_dirs: list[Path] = [proj_dir]
    include_dirs: list[Path] = [proj_dir]
    explicit_headers: list[Path] = []
    discovered_deps: list[tuple[Path, str]] = []

    # 1) AdditionalLibraryDirectories & AdditionalIncludeDirectories の収集
    for elem in root.iter():
        tag = local_tag(elem)
        if tag == "AdditionalLibraryDirectories" and elem.text:
            for token in elem.text.split(";"):
                tok = token.strip().replace("$(ProjectDir)", "").replace("\\", "/")
                if tok and not tok.startswith("%("):
                    d = (proj_dir / tok).resolve()
                    if d.is_dir() and d not in lib_dirs:
                        lib_dirs.append(d)
        elif tag == "AdditionalIncludeDirectories" and elem.text:
            for token in elem.text.split(";"):
                tok = token.strip().replace("$(ProjectDir)", "").replace("\\", "/")
                if tok and not tok.startswith("%("):
                    d = (proj_dir / tok).resolve()
                    if d.is_dir() and d not in include_dirs:
                        include_dirs.append(d)
        elif tag == "ClInclude":
            inc_attr = elem.attrib.get("Include", "")
            if inc_attr:
                resolved_h = resolve_windows_or_relative_path(inc_attr, proj_dir, root_dir, file_index)
                if resolved_h and resolved_h not in explicit_headers:
                    explicit_headers.append(resolved_h)

    # 2) AdditionalDependencies (.lib)
    for elem in root.iter():
        if local_tag(elem) == "AdditionalDependencies" and elem.text:
            for token in elem.text.split(";"):
                tok = token.strip()
                if not tok or tok.startswith("%(") or tok.lower() in SYSTEM_LIBS:
                    continue
                resolved: Path | None = None
                for ldir in lib_dirs:
                    cand = (ldir / tok.replace("\\", "/")).resolve()
                    if cand.is_file():
                        resolved = cand
                        break
                if resolved is None:
                    resolved = resolve_windows_or_relative_path(tok, proj_dir, root_dir, file_index)
                if resolved is not None:
                    discovered_deps.append((resolved, f"{vcxproj_path.name}(AdditionalDependencies)"))

    # 3) Reference / HintPath (.NET .dll)
    for elem in root.iter():
        if local_tag(elem) == "Reference":
            for child in elem:
                if local_tag(child) == "HintPath" and child.text:
                    resolved = resolve_windows_or_relative_path(child.text, proj_dir, root_dir, file_index)
                    if resolved is not None:
                        discovered_deps.append((resolved, f"{vcxproj_path.name}(Reference/HintPath)"))

    # 4) ProjectReference (参照先 .vcxproj の出力 .lib/.dll およびインクルードディレクトリ)
    for elem in root.iter():
        if local_tag(elem) == "ProjectReference":
            inc_proj = elem.attrib.get("Include", "")
            if not inc_proj:
                continue
            ref_vcxproj = resolve_windows_or_relative_path(inc_proj, proj_dir, root_dir, file_index)
            if ref_vcxproj and ref_vcxproj.is_file():
                ref_dir = ref_vcxproj.parent
                ref_stem = ref_vcxproj.stem.lower()
                # 参照先プロジェクト配下の生成物 (.lib / .dll) を検索
                for sub_file in ref_dir.rglob("*"):
                    if sub_file.is_file() and sub_file.suffix.lower() in (".lib", ".dll"):
                        if sub_file.stem.lower() == ref_stem:
                            discovered_deps.append((sub_file.resolve(), f"{vcxproj_path.name}(ProjectReference)"))
                # 参照先プロジェクトの include も追加
                _, ref_inc_dirs, ref_headers = parse_vcxproj(ref_vcxproj, product_dir, root_dir, file_index)
                for d in ref_inc_dirs:
                    if d not in include_dirs:
                        include_dirs.append(d)
                for h in ref_headers:
                    if h not in explicit_headers:
                        explicit_headers.append(h)

    return discovered_deps, include_dirs, explicit_headers


def parse_tlog_file(
    tlog_path: Path,
    product_dir: Path,
    root_dir: Path,
    file_index: dict[str, list[Path]],
    target_extensions: tuple[str, ...],
) -> list[Path]:
    """
    link.read.1.tlog または CL.read.1.tlog を解析し、参照されている実ファイルパスのリストを返す
    """
    text = read_text_auto_encoding(tlog_path)
    results: list[Path] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("^") or line.startswith("#"):
            continue
        lower = line.lower()
        if not lower.endswith(target_extensions):
            continue
        resolved = resolve_windows_or_relative_path(line, product_dir, root_dir, file_index)
        if resolved and resolved not in results:
            results.append(resolved)
    return results


def find_matching_header(
    dep_path: Path,
    tlog_headers: list[Path],
    include_dirs: list[Path],
    explicit_headers: list[Path],
    product_dir: Path,
) -> Path | None:
    """
    .lib / .dll に対応する .h ファイルを以下の優先順で特定する:
      1. CL.read.1.tlog や ClInclude / AdditionalIncludeDirectories 内の同名ヘッダ (<stem>.h)
      2. 同一モジュール配下 (親フォルダの include/ 等) の同名ヘッダ (<stem>.h)
      3. 同一モジュール配下に1つだけ存在する .h ファイル
    """
    stem_lower = dep_path.stem.lower()
    candidate_headers: list[Path] = []

    for h in tlog_headers + explicit_headers:
        if h not in candidate_headers:
            candidate_headers.append(h)

    for inc_dir in include_dirs:
        if inc_dir.is_dir():
            for h in sorted(inc_dir.rglob("*.h")):
                h_res = h.resolve()
                if h_res not in candidate_headers:
                    candidate_headers.append(h_res)

    # 1) 候補ヘッダの中からファイル名(stem)が一致するものを探す
    #    同一モジュールディレクトリに近いものを優先
    stem_matches = [h for h in candidate_headers if h.stem.lower() == stem_lower]
    if stem_matches:
        dep_parent = dep_path.parent.parent
        for h in stem_matches:
            if dep_parent in h.parents:
                return h
        return stem_matches[0]

    # 2) 対象 .lib/.dll の親または1つ上の階層 (モジュールルート) 配下の include/*.h を探す
    module_roots = [dep_path.parent]
    if dep_path.parent.name.lower() in ("lib", "libs", "bin", "x64", "x86", "release", "debug"):
        module_roots.append(dep_path.parent.parent)

    for mroot in module_roots:
        if not mroot.is_dir() or mroot == product_dir.parent:
            continue
        local_headers = sorted(mroot.rglob("*.h"))
        for h in local_headers:
            if h.stem.lower() == stem_lower:
                return h.resolve()
        if len(local_headers) == 1:
            return local_headers[0].resolve()

    return None


def evaluate_version(
    dep_path: Path,
    header_path: Path | None,
    stop_dir: Path,
) -> tuple[str, str, str, str]:
    """
    指定された優先順位に従ってバージョンを決定する:
      バイナリ情報(.dll) ＞ フォルダ名 ＞ #define ＞ 改訂履歴コメント ＞ 更新日時
    戻り値: (version, version_source, status, notes)
    """
    # 1. バイナリ情報 (.dll)
    if dep_path.suffix.lower() == ".dll":
        ver, note = extract_dll_binary_version(dep_path)
        if ver:
            return ver, "バイナリ情報(.dll)", "OK", note

    # 2. 親フォルダ名
    ver, note = extract_folder_version(dep_path, header_path, stop_dir)
    if ver:
        return ver, "フォルダ名", "OK", note

    # 3. ヘッダファイルの #define
    if header_path and header_path.is_file():
        ver, note = extract_define_version(header_path)
        if ver:
            return ver, "#define", "OK", f"{header_path.name}: {note}"

        # 4. ヘッダファイルの改訂履歴コメント
        ver, source, status, note = extract_revision_history_version(header_path)
        if ver:
            return ver, source, status, f"{header_path.name}: {note}"

    # 5. 更新日時 (タイムスタンプフォールバック)
    ver, note = extract_timestamp_version(dep_path)
    return ver, "更新日時", "OK", note


def analyze_product(
    product_dir: Path,
    root_dir: Path,
    file_index: dict[str, list[Path]],
) -> list[DependencyRecord]:
    """
    製品フォルダ (例: ProductA, ProductB) 配下の依存 .lib / .dll を収集し、バージョンを特定する
    """
    product_name = product_dir.name
    records_by_path: dict[Path, DependencyRecord] = {}

    def register_dep(file_path: Path, source_label: str) -> None:
        resolved = file_path.resolve()
        if resolved.name.lower() in SYSTEM_LIBS:
            return
        try:
            rel_path = resolved.relative_to(root_dir.resolve()).as_posix()
        except ValueError:
            rel_path = resolved.as_posix()

        if resolved not in records_by_path:
            records_by_path[resolved] = DependencyRecord(
                product=product_name,
                file_path=resolved,
                file_name=resolved.name,
                file_type=resolved.suffix.lower(),
                relative_path=rel_path,
                detected_in=[source_label],
            )
        else:
            if source_label not in records_by_path[resolved].detected_in:
                records_by_path[resolved].detected_in.append(source_label)

    include_dirs: list[Path] = []
    explicit_headers: list[Path] = []
    tlog_headers: list[Path] = []

    # 1) ルート直下のメイン .vcxproj (またはサブプロジェクトを含む .vcxproj) を解析
    vcxproj_files = sorted(product_dir.rglob("*.vcxproj"))
    # メインプロジェクト (製品フォルダ直下) を優先解析
    for vcx in vcxproj_files:
        if vcx.parent == product_dir or len(vcxproj_files) == 1:
            deps, inc_dirs, exp_hdrs = parse_vcxproj(vcx, product_dir, root_dir, file_index)
            for dep_path, label in deps:
                register_dep(dep_path, label)
            for d in inc_dirs:
                if d not in include_dirs:
                    include_dirs.append(d)
            for h in exp_hdrs:
                if h not in explicit_headers:
                    explicit_headers.append(h)

    # 2) link.read.1.tlog / CL.read.1.tlog の解析
    for link_tlog in sorted(product_dir.rglob("link.read.*.tlog")):
        for dep_path in parse_tlog_file(link_tlog, product_dir, root_dir, file_index, (".lib", ".dll")):
            register_dep(dep_path, link_tlog.name)

    for cl_tlog in sorted(product_dir.rglob("CL.read.*.tlog")):
        for hdr_path in parse_tlog_file(cl_tlog, product_dir, root_dir, file_index, (".h", ".hpp")):
            if hdr_path not in tlog_headers:
                tlog_headers.append(hdr_path)

    # 3) 製品フォルダ配下に存在する .lib / .dll のディレクトリ走査 (bin/ 配下の DLL 等も漏れなく収集)
    for fpath in sorted(product_dir.rglob("*")):
        if fpath.is_file() and fpath.suffix.lower() in (".lib", ".dll"):
            register_dep(fpath, "DirectoryScan")

    # 4) 各 .lib / .dll に対応する .h ファイルを紐付け、優先順位に従ってバージョン抽出
    records = sorted(records_by_path.values(), key=lambda r: (r.file_type, r.file_name.lower()))
    for rec in records:
        rec.header_path = find_matching_header(
            rec.file_path,
            tlog_headers=tlog_headers,
            include_dirs=include_dirs,
            explicit_headers=explicit_headers,
            product_dir=product_dir,
        )
        ver, ver_source, status, notes = evaluate_version(
            rec.file_path,
            rec.header_path,
            stop_dir=root_dir,
        )
        rec.version = ver
        rec.version_source = ver_source
        rec.status = status
        rec.notes = notes

    return records


def export_inventory_csv(root_dir: Path, output_csv: Path) -> list[DependencyRecord]:
    """
    指定ルートディレクトリ配下の全製品サブフォルダを走査し、UTF-8 (BOM付き) CSV に出力する
    """
    file_index = build_case_insensitive_file_index(root_dir)
    product_dirs = sorted([d for d in root_dir.iterdir() if d.is_dir() and not d.name.startswith(".")])

    all_records: list[DependencyRecord] = []
    for prod_dir in product_dirs:
        all_records.extend(analyze_product(prod_dir, root_dir, file_index))

    output_csv.parent.mkdir(parents=True, exist_ok=True)
    # Excel で文字化けしない UTF-8 (BOM付き: utf-8-sig) で出力
    with output_csv.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "Product",
                "FileName",
                "FileType",
                "RelativePath",
                "DetectedIn",
                "HeaderFile",
                "Version",
                "VersionSource",
                "Status",
                "Notes",
            ]
        )
        for rec in all_records:
            header_rel = "-"
            if rec.header_path:
                try:
                    header_rel = rec.header_path.relative_to(root_dir.resolve()).as_posix()
                except ValueError:
                    header_rel = rec.header_path.as_posix()

            writer.writerow(
                [
                    rec.product,
                    rec.file_name,
                    rec.file_type,
                    rec.relative_path,
                    "; ".join(rec.detected_in),
                    header_rel,
                    rec.version,
                    rec.version_source,
                    rec.status,
                    rec.notes,
                ]
            )

    return all_records


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Windowsアプリ製品フォルダ配下から依存 .lib / .dll とバージョンを抽出してCSV出力するツール"
    )
    parser.add_argument(
        "-i",
        "--input-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "test_env",
        help="走査対象のルートフォルダ (デフォルト: ./test_env)",
    )
    parser.add_argument(
        "-o",
        "--output-csv",
        type=Path,
        default=Path(__file__).resolve().parent / "lib_dll_inventory.csv",
        help="出力CSVファイルパス (デフォルト: ./lib_dll_inventory.csv)",
    )
    args = parser.parse_args()

    records = export_inventory_csv(args.input_dir, args.output_csv)
    print(f"[INFO] 抽出完了: 合計 {len(records)} 件の依存ファイルを '{args.output_csv}' (UTF-8 BOM付き) に出力しました。\n")
    print(f"{'Product':<10} | {'FileName':<22} | {'Version':<28} | {'VersionSource':<22} | {'Status'}")
    print("-" * 102)
    for r in records:
        print(f"{r.product:<10} | {r.file_name:<22} | {r.version:<28} | {r.version_source:<22} | {r.status}")


if __name__ == "__main__":
    main()
