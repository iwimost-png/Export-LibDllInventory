<#
.SYNOPSIS
    Export-LibDllInventory.ps1 の抽出結果 (LibDllInventory.csv) が全テストケースの期待値と一致するか自動検証します。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = (Join-Path $PSScriptRoot 'LibDllInventory.csv')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 1. 環境構築と抽出の実行
& (Join-Path $PSScriptRoot 'Initialize-TestEnv.ps1') | Out-Null
& (Join-Path $PSScriptRoot 'Export-LibDllInventory.ps1') -OutputCsvPath $CsvPath | Out-Null

# 2. UTF-8 BOM (0xEF, 0xBB, 0xBF) の検証
$bytes = [System.IO.File]::ReadAllBytes($CsvPath)
if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
    throw "CSVファイルに UTF-8 BOM (EF BB BF) が付与されていません。"
}
Write-Host "[PASS] UTF-8 (BOM付き) エンコーディング確認: 0xEF 0xBB 0xBF" -ForegroundColor Green

# 3. 各パターンの抽出結果検証
$rows = Import-Csv -LiteralPath $CsvPath -Encoding UTF8

$expectedCases = @(
    @{
        Desc          = '優先度1: バイナリ情報(.dll) ＞ フォルダ名 (PluginSdk_v1.8.0 配下の 1.8.2.0 DLL)'
        Product       = 'ProductA'
        FileName      = 'PluginSdk.dll'
        Version       = '1.8.2.0'
        VersionSource = 'バイナリ情報(.dll)'
        Status        = 'OK'
    },
    @{
        Desc          = '優先度2: フォルダ名 ＞ #define (ThirdParty_v2.4.1 配下、ヘッダ内 #define 2.0.0)'
        Product       = 'ProductA'
        FileName      = 'ThirdParty.lib'
        Version       = '2.4.1'
        VersionSource = 'フォルダ名'
        Status        = 'OK'
    },
    @{
        Desc          = '優先度2(英字直結): Lua5.4.6 フォルダ名からメジャー欠落なく 5.4.6 を抽出'
        Product       = 'ProductA'
        FileName      = 'Lua.lib'
        Version       = '5.4.6'
        VersionSource = 'フォルダ名'
        Status        = 'OK'
    },
    @{
        Desc          = '優先度3(a): #define 定義 (コメントアウトされたダミー定義除外 ＋ #define ＞ 改訂履歴)'
        Product       = 'ProductA'
        FileName      = 'AlphaDef.lib'
        Version       = '1.4.2'
        VersionSource = '#define'
        Status        = 'OK'
    },
    @{
        Desc          = '優先度3(a-2): tlogからのみ検出 ＋ MAJOR/MINOR/PATCH 分割 #define ＋ プロジェクト名特定'
        Product       = 'ProductA'
        FileName      = 'TlogOnlyLib.lib'
        Version       = '3.1.4'
        VersionSource = '#define'
        Status        = 'OK'
        Project       = 'ProductA.vcxproj'
    },
    @{
        Desc          = '優先度3(a-3): 末尾verヘッダ名(Server.h) ＋ //内/* ＋ ネスト#if 0除外'
        Product       = 'ProductA'
        FileName      = 'Server.lib'
        Version       = '2.7.0'
        VersionSource = '#define'
        Status        = 'OK'
        HeaderFile    = 'ProductA\include\Server.h'
    },
    @{
        Desc          = 'ProjectReference 経由の依存検出 ＋ #define'
        Product       = 'ProductA'
        FileName      = 'SubCore.lib'
        Version       = '1.1.0'
        VersionSource = '#define'
        Status        = 'OK'
    },
    @{
        Desc          = '優先度4(b): 改訂履歴コメント（上が最新の降順パターン）'
        Product       = 'ProductA'
        FileName      = 'BetaDesc.lib'
        Version       = '2.3.0'
        VersionSource = '改訂履歴コメント(降順)'
        Status        = 'OK'
    },
    @{
        Desc          = '優先度4(c): 改訂履歴コメント（下が最新の昇順パターン）'
        Product       = 'ProductA'
        FileName      = 'GammaAsc.lib'
        Version       = '1.2.5'
        VersionSource = '改訂履歴コメント(昇順)'
        Status        = 'OK'
    },
    @{
        Desc          = '優先度4(c-5): ヘッダ(1.420N) vs ソース(1.425P) 差異あり -> 最新のソース側 1.425P を採用'
        Product       = 'ProductA'
        FileName      = 'HistDiffSrcNewer.lib'
        Version       = '1.425P'
        VersionSource = '改訂履歴コメント(降順)'
        Status        = 'OK'
        HeaderFile    = 'ProductA\include\HistDiffSrcNewer.h'
        SourceFile    = 'ProductA\src\HistDiffSrcNewer.cpp'
    },
    @{
        Desc          = '優先度4(c-6): ヘッダ(1.420P) vs ソース(1.420N) 英文字比較 -> 最新のヘッダ側 1.420P を採用'
        Product       = 'ProductA'
        FileName      = 'HistDiffHdrNewer.lib'
        Version       = '1.420P'
        VersionSource = '改訂履歴コメント(昇順)'
        Status        = 'OK'
        HeaderFile    = 'ProductA\include\HistDiffHdrNewer.h'
        SourceFile    = 'ProductA\src\HistDiffHdrNewer.cpp'
    },
    @{
        Desc          = '優先度4(c-7): ヘッダなし・ソースコードのみ(1.420N->1.425P) -> 1.425P を抽出'
        Product       = 'ProductB'
        FileName      = 'SourceOnlyHist.lib'
        Version       = '1.425P'
        VersionSource = '改訂履歴コメント(昇順)'
        Status        = 'OK'
        SourceFile    = 'ProductB\src\SourceOnlyHist.cpp'
    },
    @{
        Desc          = '優先度1(.NET混在): .vcxproj / .csproj 双方から参照されるバイナリ情報付き .dll'
        Product       = 'ProductB'
        FileName      = 'ManagedCore.dll'
        Version       = '3.5.1.0'
        VersionSource = 'バイナリ情報(.dll)'
        Status        = 'OK'
    },
    @{
        Desc          = 'DLLバイナリ情報なし時のフォールバック: 対応する .h の #define から抽出'
        Product       = 'ProductB'
        FileName      = 'LegacyNative.dll'
        Version       = '4.0.1'
        VersionSource = '#define'
        Status        = 'OK'
    },
    @{
        Desc          = '優先度3(複数ヘッダ＋同一プレフィックス): MultiPkgVersion.h の MULTIPKG_* を結合'
        Product       = 'ProductB'
        FileName      = 'MultiPkg.lib'
        Version       = '1.6.3'
        VersionSource = '#define'
        Status        = 'OK'
        HeaderFile    = 'ProductB\MultiHeaderPkg\include\MultiPkgVersion.h'
    },
    @{
        Desc          = '優先度4(同一バージョン履歴): 全行 1.0.0 の場合は重複確認せず OK 判定'
        Product       = 'ProductB'
        FileName      = 'SameVerHistory.lib'
        Version       = '1.0.0'
        VersionSource = '改訂履歴コメント'
        Status        = 'OK'
    },
    @{
        Desc          = '優先度4(一部日付欠落・矛盾): 日付矛盾を検知して要目視確認フラグを設定'
        Product       = 'ProductB'
        FileName      = 'PartialDateConflict.lib'
        Version       = '先頭: 2.0.0 / 末尾: 1.8.0'
        VersionSource = '改訂履歴コメント(順序不明)'
        Status        = '要目視確認'
    },
    @{
        Desc          = '優先度4(順序不明): 改訂履歴の昇順・降順が判別不能 → 先頭と末尾の両方出力 ＋ 要目視確認'
        Product       = 'ProductB'
        FileName      = 'EpsilonAmbiguous.lib'
        Version       = '先頭: 2.1.0 / 末尾: 1.9.0'
        VersionSource = '改訂履歴コメント(順序不明)'
        Status        = '要目視確認'
    },
    @{
        Desc          = '優先度5(e): バージョン記載なし → ファイル更新日時へのフォールバック'
        Product       = 'ProductB'
        FileName      = 'DeltaNoVer.lib'
        Version       = '2024-08-20 14:30:00'
        VersionSource = '更新日時'
        Status        = 'OK'
    }
)

$failed = 0
foreach ($exp in $expectedCases) {
    $match = @($rows | Where-Object { $_.Product -eq $exp.Product -and $_.FileName -eq $exp.FileName })
    if ($match.Count -ne 1) {
        Write-Host "[FAIL] $($exp.Desc) -> 該当行が見つかりません ($($exp.Product) / $($exp.FileName))" -ForegroundColor Red
        $failed++
        continue
    }
    $row = $match[0]
    $mismatch = ($row.Version -ne $exp.Version -or $row.VersionSource -ne $exp.VersionSource -or $row.Status -ne $exp.Status)
    if ($exp.ContainsKey('Project') -and $row.Project -ne $exp.Project) { $mismatch = $true }
    if ($exp.ContainsKey('HeaderFile') -and $row.HeaderFile -ne $exp.HeaderFile) { $mismatch = $true }
    if ($exp.ContainsKey('SourceFile') -and $row.SourceFile -ne $exp.SourceFile) { $mismatch = $true }

    if ($mismatch) {
        Write-Host "[FAIL] $($exp.Desc)" -ForegroundColor Red
        Write-Host "       期待値: Version='$($exp.Version)', Source='$($exp.VersionSource)', Status='$($exp.Status)'" -ForegroundColor Red
        Write-Host "       実際値: Version='$($row.Version)', Source='$($row.VersionSource)', Status='$($row.Status)', Project='$($row.Project)', Header='$($row.HeaderFile)'" -ForegroundColor Red
        $failed++
    }
    else {
        Write-Host "[PASS] $($exp.Desc) => Version='$($row.Version)', Source='$($row.VersionSource)', Status='$($row.Status)'" -ForegroundColor Green
    }
}

# 4. 中間ビルドフォルダ (obj/) 除外の検証
$intermediateMatch = @($rows | Where-Object { $_.FileName -eq 'IntermediateDummy.dll' })
if ($intermediateMatch.Count -gt 0) {
    Write-Host "[FAIL] 中間ビルドフォルダ (obj/) 内の IntermediateDummy.dll が誤抽出されました。" -ForegroundColor Red
    $failed++
}
else {
    Write-Host "[PASS] 中間ビルドフォルダ (obj/) 内の DLL が除外されていることを確認" -ForegroundColor Green
}

# 5. 単一製品モード ＋ 製品フォルダ外共有ライブラリ (..\Shared\CommonSdk_v3.2.1) 参照の検証
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("InvTest_" + [System.Guid]::NewGuid().ToString('N'))
try {
    $appDir = Join-Path $tempRoot 'MyApp'
    $extLibDir = Join-Path $tempRoot 'Shared\CommonSdk_v3.2.1\lib'
    New-Item -ItemType Directory -Path $appDir, $extLibDir -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $extLibDir 'CommonSdk.lib'), [System.Text.Encoding]::ASCII.GetBytes("!<arch>`n"))
    $vcxText = @'
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemDefinitionGroup>
    <Link>
      <AdditionalDependencies>..\Shared\CommonSdk_v3.2.1\lib\CommonSdk.lib;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
</Project>
'@
    [System.IO.File]::WriteAllText((Join-Path $appDir 'MyApp.vcxproj'), $vcxText, (New-Object System.Text.UTF8Encoding($true)))
    $tempCsv = Join-Path $tempRoot 'out.csv'
    $extRows = @(& (Join-Path $PSScriptRoot 'Export-LibDllInventory.ps1') -RootPath $appDir -OutputCsvPath $tempCsv -PassThru)
    $extMatch = @($extRows | Where-Object { $_.FileName -eq 'CommonSdk.lib' })
    if ($extMatch.Count -eq 1 -and $extMatch[0].Version -eq '3.2.1' -and $extMatch[0].VersionSource -eq 'フォルダ名') {
        Write-Host "[PASS] 製品フォルダ外の相対パス共有ライブラリ (..\Shared\CommonSdk_v3.2.1) から 3.2.1 を抽出" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] 製品フォルダ外の共有ライブラリ抽出に失敗しました" -ForegroundColor Red
        $failed++
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if ($failed -gt 0) {
    throw "検証失敗: $failed 件のテストケースが期待値と一致しませんでした。"
}
Write-Host "`n全テストケースの検証に成功しました。" -ForegroundColor Cyan
