# Export-LibDllInventory

Windowsアプリ（C++ / .NET混在想定）の製品フォルダ配下から、依存している `.lib` / `.dll` と各バージョンを**ルールベース（正規表現＋メタデータのみ、AI不使用）**で機械的に抽出し、Excelで文字化けしない **UTF-8 (BOM付き) CSV** に出力するツールおよび動作確認用テスト環境です。

## 構成ファイル

- `export_lib_dll_inventory.py` : バージョン・依存関係抽出スクリプト（Python 3 標準ライブラリのみ・Windows / Linux 両対応）
- `Export-LibDllInventory.ps1` : バージョン・依存関係抽出スクリプト（PowerShell 版）
- `setup_test_env.py` : テスト用ダミー環境 (`test_env/`) を再生成するスクリプト
- `verify_inventory.py` : 出力された `lib_dll_inventory.csv` の全パターン自動検証スクリプト
- `test_env/` : 動作確認用ダミーテスト環境（`ProductA`, `ProductB`）
- `lib_dll_inventory.csv` : 抽出結果CSV（UTF-8 BOM付き）

## バージョン抽出の優先順位とルール

以下の優先順位でバージョンを決定します：

1. **バイナリ情報 (`.dll`)**
   - PE バイナリの `VS_VERSION_INFO` リソース (`FileVersion` / `ProductVersion` / `VS_FIXEDFILEINFO`) から抽出
2. **フォルダ名**
   - 親フォルダ名に含まれるバージョン表記（例: `ThirdParty_v2.4.1` → `2.4.1`）
3. **`#define` 定義 (`.h`)**
   - ブロックコメント (`/* ... */`) や行コメント (`// ...`) 内のダミー定義を除去した上で、有効な `#define`（単一文字列マクロおよび `MAJOR`/`MINOR`/`PATCH` 分割マクロ）から抽出
4. **改訂履歴コメント (`.h`)**
   - コメント内の日付とバージョンの推移から **降順（上が最新）** / **昇順（下が最新）** を自動判別して最新バージョンを抽出
   - 昇順・降順が判別できない場合は **「先頭と末尾」を両方出力**（例: `先頭: 2.1.0 / 末尾: 1.9.2`）し、`Status` 列に **`要目視確認`** フラグを設定
5. **更新日時（タイムスタンプフォールバック）**
   - 上記いずれでもバージョンが特定できない場合、対象ファイルの最終更新日時 (`YYYY-MM-DD HH:MM:SS`) を出力

## 使い方

### Python 版
```bash
# デフォルト (./test_env を走査し ./lib_dll_inventory.csv に出力)
python3 export_lib_dll_inventory.py

# 入出力パスを指定する場合
python3 export_lib_dll_inventory.py -i ./test_env -o ./lib_dll_inventory.csv

# 検証スクリプトの実行
python3 verify_inventory.py
```

### PowerShell 版 (Windows)
```powershell
.\Export-LibDllInventory.ps1 -InputDir .\test_env -OutputCsv .\lib_dll_inventory.csv
```
