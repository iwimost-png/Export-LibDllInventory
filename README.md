# Export-LibDllInventory

Windowsアプリ（C++ / .NET 混在想定）の製品フォルダ配下から、依存している `.lib` / `.dll` と各バージョンをルールベース（正規表現＋メタデータ）で機械的に抽出し、Excel で文字化けしない **UTF-8 (BOM付き) CSV** に出力するツールおよび動作確認用テスト環境です。

## ファイル構成

- `Export-LibDllInventory.ps1` : 依存関係・バージョン抽出スクリプト本体
- `Initialize-TestEnv.ps1` : 動作確認用ダミー環境（`test_env/`）生成スクリプト
- `Test-LibDllInventory.ps1` : 全テストケースの自動検証スクリプト
- `LibDllInventory.csv` : `test_env/` に対する抽出結果CSV（UTF-8 BOM付き）
- `test_env/` : ダミー製品環境（`ProductA`, `ProductB`）

## バージョン抽出ルールと優先順位

AIを使用せず、以下の優先順位で正規表現とメタデータから機械的にバージョンを決定します。

1. **バイナリ情報 (`.dll`)**
   - `[System.Diagnostics.FileVersionInfo]::GetVersionInfo()` により `FileVersion` / `ProductVersion` を取得（`0.0.0.0` 等の空バージョンは除外）
2. **フォルダ名**
   - 親フォルダ階層からバージョン表記（例: `ThirdParty_v2.4.1`, `PluginSdk_v1.8.0`）を正規表現で抽出
3. **`#define`（対応する `.h` ファイル）**
   - ブロックコメント `/* ... */`、単一行コメント `// ...`、`#if 0 ... #endif` ブロックを除去した上で有効な `#define` から抽出
   - 単一文字列マクロ（`#define XXX_VERSION "1.4.2"`）および分割マクロ（`MAJOR` / `MINOR` / `PATCH`）の両方に対応
4. **改訂履歴コメント（対応する `.h` ファイル）**
   - コメント内の履歴行から日付・バージョン列を抽出し、**降順（上が最新）** / **昇順（下が最新）** を自動判定
   - 昇順・降順が判別できない場合（非単調な履歴や日付・バージョンの矛盾など）は **`先頭: X.X.X / 末尾: Y.Y.Y`** を両方出力し、`Status` 列に **`要目視確認`** フラグを設定
5. **更新日時（タイムスタンプフォールバック）**
   - 上記すべてでバージョンが特定できない場合、対象ファイルの `LastWriteTime` (`yyyy-MM-dd HH:mm:ss`) を出力

## 使い方

```powershell
# 1. テスト環境の再生成（必要に応じて）
.\Initialize-TestEnv.ps1

# 2. 依存関係・バージョン抽出の実行（既定で .\test_env を走査し .\LibDllInventory.csv に出力）
.\Export-LibDllInventory.ps1 -RootPath .\test_env -OutputCsvPath .\LibDllInventory.csv

# 3. 自動検証テストの実行
.\Test-LibDllInventory.ps1
```
