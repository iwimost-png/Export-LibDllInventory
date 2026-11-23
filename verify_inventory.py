#!/usr/bin/env python3
"""
verify_inventory.py
抽出された CSV (lib_dll_inventory.csv) と test_env/ の構成が
全要件・全パターンを正しく満たしているか自動検証するスクリプト。
"""

import csv
from pathlib import Path


def main() -> None:
    repo_root = Path(__file__).resolve().parent
    csv_path = repo_root / "lib_dll_inventory.csv"
    test_env = repo_root / "test_env"

    # 1. BOM (EF BB BF) の検証
    raw_bytes = csv_path.read_bytes()
    assert raw_bytes.startswith(b"\xef\xbb\xbf"), "エラー: CSVファイルに UTF-8 BOM (EF BB BF) が付与されていません"
    print("[PASS] CSV ファイルの UTF-8 (BOM付き) フォーマットを確認しました。")

    # 2. テスト環境の必須構成チェック
    required_paths = [
        test_env / "ProductA" / "ProductA.vcxproj",
        test_env / "ProductA" / "x64" / "Release" / "ProductA.tlog" / "link.read.1.tlog",
        test_env / "ProductA" / "x64" / "Release" / "ProductA.tlog" / "CL.read.1.tlog",
        test_env / "ProductB" / "ProductB.vcxproj",
        test_env / "ProductB" / "x64" / "Release" / "ProductB.tlog" / "link.read.1.tlog",
        test_env / "ProductB" / "x64" / "Release" / "ProductB.tlog" / "CL.read.1.tlog",
    ]
    for p in required_paths:
        assert p.is_file(), f"エラー: 必須テストファイルが存在しません: {p}"
    print("[PASS] test_env/ 配下の製品フォルダ・.vcxproj・.tlog ファイル構成を確認しました。")

    # 3. CSV 行内容の検証
    with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))

    by_key = {(r["Product"], r["FileName"]): r for r in rows}

    expected_cases = [
        # (Product, FileName, ExpectedVersion, ExpectedSource, ExpectedStatus, Description)
        (
            "ProductA",
            "ImageEngine.dll",
            "4.5.2.0",
            "バイナリ情報(.dll)",
            "OK",
            "優先度1: .dll バイナリ情報 (PE VS_VERSION_INFO) が #define (4.0.0) より優先されること",
        ),
        (
            "ProductA",
            "thirdparty_math.dll",
            "2.4.1",
            "フォルダ名",
            "OK",
            "優先度2(d): バージョンリソースなし .dll で親フォルダ名 (ThirdParty_v2.4.1) が #define (2.0.0) より優先されること",
        ),
        (
            "ProductA",
            "thirdparty_math.lib",
            "2.4.1",
            "フォルダ名",
            "OK",
            "優先度2(d): .lib で親フォルダ名 (ThirdParty_v2.4.1) が #define (2.0.0) より優先されること",
        ),
        (
            "ProductA",
            "algocore.lib",
            "1.8.3",
            "#define",
            "OK",
            "優先度3(a): コメントアウトされたダミー #define を無視し、有効な #define を抽出できること",
        ),
        (
            "ProductA",
            "CommonLogger.lib",
            "2.1.4",
            "#define",
            "OK",
            "優先度3(a) + ProjectReference: MAJOR/MINOR/PATCH 分割 #define と ProjectReference 解決",
        ),
        (
            "ProductA",
            "ImageEngine.lib",
            "4.0.0",
            "#define",
            "OK",
            "優先度3(a): .lib 側では対応ヘッダの有効な #define (4.0.0) が抽出されること",
        ),
        (
            "ProductA",
            "netclient.lib",
            "3.4.0",
            "改訂履歴コメント(降順)",
            "OK",
            "優先度4(b): 改訂履歴コメント（上が最新の降順パターン）から先頭の最新バージョンを抽出できること",
        ),
        (
            "ProductB",
            "DotNetAnalytics.dll",
            "5.12.0.104",
            "バイナリ情報(.dll)",
            "OK",
            "優先度1: .NET Reference (HintPath) の .dll からバイナリバージョン情報を抽出できること",
        ),
        (
            "ProductB",
            "serialcomm.lib",
            "1.3.0",
            "改訂履歴コメント(昇順)",
            "OK",
            "優先度4(c): 改訂履歴コメント（下が最新の昇順パターン）から末尾の最新バージョンを抽出できること",
        ),
        (
            "ProductB",
            "legacy_parser.lib",
            "先頭: 2.1.0 / 末尾: 1.9.2",
            "改訂履歴コメント(順序不明)",
            "要目視確認",
            "優先度4(順序不明): 昇順・降順が判別できない場合は「先頭と末尾」を両方出力し Status 列に「要目視確認」を立てること",
        ),
        (
            "ProductB",
            "rawdevice.lib",
            "2024-09-15 14:20:00",
            "更新日時",
            "OK",
            "優先度5(e): バージョン記載なしの場合にファイルの更新日時（タイムスタンプ）にフォールバックすること",
        ),
        (
            "ProductB",
            "CommonLogger.lib",
            "2.1.4",
            "#define",
            "OK",
            "ProductB からの製品横断 ProjectReference (..\\ProductA\\CommonLogger) の解決",
        ),
    ]

    for prod, fname, exp_ver, exp_src, exp_status, desc in expected_cases:
        key = (prod, fname)
        assert key in by_key, f"エラー: CSV に {key} の行が存在しません"
        row = by_key[key]
        assert row["Version"] == exp_ver, (
            f"エラー [{prod}/{fname}]: Version 期待値='{exp_ver}', 実際='{row['Version']}'"
        )
        assert row["VersionSource"] == exp_src, (
            f"エラー [{prod}/{fname}]: VersionSource 期待値='{exp_src}', 実際='{row['VersionSource']}'"
        )
        assert row["Status"] == exp_status, (
            f"エラー [{prod}/{fname}]: Status 期待値='{exp_status}', 実際='{row['Status']}'"
        )
        print(f"[PASS] {prod}/{fname:<20} -> Version='{exp_ver}', Source='{exp_src}', Status='{exp_status}' ({desc})")

    print("\nすべての検証項目をパスしました！")


if __name__ == "__main__":
    main()
