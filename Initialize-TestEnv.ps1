<#
.SYNOPSIS
    依存ライブラリ(.lib / .dll) バージョン抽出ツールの動作確認用ダミー環境 (test_env/) を生成します。

.DESCRIPTION
    以下のテストケースを網羅するダミー製品フォルダ (ProductA, ProductB) を test_env/ 配下に構築します。
    - 複数の製品サブフォルダ (ProductA, ProductB)
    - .vcxproj (AdditionalDependencies, ProjectReference, AdditionalIncludeDirectories 等を含む)
    - .csproj (.NET混在構成の参照確認用)
    - link.read.1.tlog / CL.read.1.tlog
    - バージョン記載方法が異なる複数の .h ファイル
      (a) #define で定義（コメントアウトされたダミー定義や分割マクロも含む）
      (b) 改訂履歴コメント（上が最新の降順パターン）
      (c) 改訂履歴コメント（下が最新の昇順パターン）
      (c-2) 改訂履歴コメント（昇順・降順が判別できないパターン → 要目視確認）
      (d) 親フォルダ名にバージョン表記（例: ThirdParty_v2.4.1）
      (e) バージョン記載なし（タイムスタンプフォールバック確認用）
    - ダミーの .lib と .dll（バイナリバージョン情報付き実PE DLL / バージョン情報なしダミーDLL）
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$BaseDir = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testEnvRoot = Join-Path $BaseDir 'test_env'
if (Test-Path -LiteralPath $testEnvRoot) {
    Remove-Item -LiteralPath $testEnvRoot -Recurse -Force
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf16Le = New-Object System.Text.UnicodeEncoding($false, $true)

function Write-TextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content,
        [System.Text.Encoding]$Encoding = $utf8Bom,
        [datetime]$Timestamp = (Get-Date '2025-04-01 09:00:00')
    )
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
    (Get-Item -LiteralPath $Path).LastWriteTime = $Timestamp
}

function Write-DummyLib {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$LibName,
        [datetime]$Timestamp = (Get-Date '2025-04-01 09:00:00')
    )
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # COFF Archive (.lib) magic header "!<arch>\n" + dummy symbol metadata
    $content = "!<arch>`n// Dummy static library: $LibName`n"
    [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::ASCII.GetBytes($content))
    (Get-Item -LiteralPath $Path).LastWriteTime = $Timestamp
}

function Write-BinaryDllWithVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ClassName,
        [Parameter(Mandatory = $true)][string]$FileVersion,
        [Parameter(Mandatory = $true)][string]$ProductVersion,
        [datetime]$Timestamp = (Get-Date '2025-04-01 09:00:00')
    )
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $csSource = @"
using System.Reflection;
[assembly: AssemblyTitle("$ClassName")]
[assembly: AssemblyVersion("$FileVersion")]
[assembly: AssemblyFileVersion("$FileVersion")]
[assembly: AssemblyInformationalVersion("$ProductVersion")]
namespace DummyInventoryTest {
    public class $ClassName {
        public static string GetName() { return "$ClassName"; }
    }
}
"@
    Add-Type -TypeDefinition $csSource -OutputAssembly $Path -OutputType Library | Out-Null
    (Get-Item -LiteralPath $Path).LastWriteTime = $Timestamp
}

function Write-DummyDllWithoutVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DllName,
        [datetime]$Timestamp = (Get-Date '2025-04-01 09:00:00')
    )
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # バージョンリソース(VS_VERSION_INFO)を持たないダミーDLLバイナリ
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("MZ`0`0DUMMY_NATIVE_DLL_NO_VERSION_RESOURCE:$DllName")
    [System.IO.File]::WriteAllBytes($Path, $bytes)
    (Get-Item -LiteralPath $Path).LastWriteTime = $Timestamp
}

# ==============================================================================
# 1. ProductA の構築
# ==============================================================================
$prodADir = Join-Path $testEnvRoot 'ProductA'

# (a) #define で定義（コメントアウトされたダミー定義も含む）+ 古い改訂履歴も含む（#define ＞ 改訂履歴 の優先度確認）
$alphaHeaderPath = Join-Path $prodADir 'include\AlphaDef.h'
$alphaHeaderContent = @'
#pragma once
#ifndef ALPHA_DEF_H
#define ALPHA_DEF_H

// 単一行コメントアウトされたダミー定義（抽出されてはならない）
// #define ALPHA_VERSION "0.8.0-commented"

/*
 * 複数行ブロックコメント内のダミー定義（抽出されてはならない）
 * #define ALPHA_VERSION "0.9.0-block-comment"
 */

#if 0
#define ALPHA_VERSION "0.9.5-disabled-block"
#endif

/*
 * 改訂履歴（#define の方が優先されることを確認するための古い履歴）
 * 2025/01/10 Ver 1.3.0 内部リファクタリング
 * 2024/06/01 Ver 1.2.0 初期リリース
 */

// 有効なバージョン定義（期待抽出値: 1.4.2）
#define ALPHA_VERSION "1.4.2"

namespace Alpha {
    int InitializeAlpha();
}

#endif // ALPHA_DEF_H
'@
Write-TextFile -Path $alphaHeaderPath -Content $alphaHeaderContent
Write-DummyLib -Path (Join-Path $prodADir 'lib\AlphaDef.lib') -LibName 'AlphaDef.lib'

# (b) 改訂履歴コメント（上が最新の降順パターン: 期待抽出値 2.3.0）
$betaHeaderPath = Join-Path $prodADir 'include\BetaDesc.h'
$betaHeaderContent = @'
#pragma once
#ifndef BETA_DESC_H
#define BETA_DESC_H

/*
 * ============================================================================
 * BetaDesc Library Header
 * 改訂履歴 (Revision History) - 上が最新の降順パターン
 * ----------------------------------------------------------------------------
 * 2026/02/15  Ver 2.3.0  高負荷時のメモリリーク修正およびSIMD最適化
 * 2025/09/10  Ver 2.2.0  非同期バッチ処理APIの追加
 * 2025/01/20  Ver 2.1.0  初版リリース
 * ============================================================================
 */

namespace Beta {
    void RunCalculation();
}

#endif // BETA_DESC_H
'@
Write-TextFile -Path $betaHeaderPath -Content $betaHeaderContent
Write-DummyLib -Path (Join-Path $prodADir 'lib\BetaDesc.lib') -LibName 'BetaDesc.lib'

# (c) 改訂履歴コメント（下が最新の昇順パターン: 期待抽出値 1.2.5）
$gammaHeaderPath = Join-Path $prodADir 'include\GammaAsc.h'
$gammaHeaderContent = @'
#pragma once
#ifndef GAMMA_ASC_H
#define GAMMA_ASC_H

/*
 * ============================================================================
 * GammaAsc Communication Header
 * 変更履歴 (Change Log) - 下が最新の昇順パターン
 * ----------------------------------------------------------------------------
 * 2023-04-01  v1.0.0  新規作成
 * 2024-06-15  v1.1.0  TLS 1.3 ハンドシェイク対応
 * 2025-11-30  v1.2.5  再接続時のタイムアウト計算バグ修正
 * ============================================================================
 */

namespace Gamma {
    bool ConnectEndpoint(const char* host);
}

#endif // GAMMA_ASC_H
'@
Write-TextFile -Path $gammaHeaderPath -Content $gammaHeaderContent
Write-DummyLib -Path (Join-Path $prodADir 'lib\GammaAsc.lib') -LibName 'GammaAsc.lib'

# (a-2) tlogのみから検出されるライブラリ (#pragma comment(lib) 想定) + 分割 #define (MAJOR/MINOR/PATCH: 期待抽出値 3.1.4)
$tlogOnlyHeaderPath = Join-Path $prodADir 'include\TlogOnlyLib.h'
$tlogOnlyHeaderContent = @'
#pragma once
// #define TLOG_LIB_VERSION_MAJOR 2
#define TLOG_LIB_VERSION_MAJOR 3
#define TLOG_LIB_VERSION_MINOR 1
#define TLOG_LIB_VERSION_PATCH 4

namespace TlogOnly {
    void WriteDiag();
}
'@
Write-TextFile -Path $tlogOnlyHeaderPath -Content $tlogOnlyHeaderContent
Write-DummyLib -Path (Join-Path $prodADir 'lib\TlogOnlyLib.lib') -LibName 'TlogOnlyLib.lib'

# (d) 親フォルダ名にバージョン表記 (ThirdParty_v2.4.1: 期待抽出値 2.4.1)
# ※ヘッダ内に #define THIRDPARTY_VERSION "2.0.0" を入れ、「フォルダ名 ＞ #define」の優先順位も検証
$thirdPartyHeaderPath = Join-Path $prodADir 'ThirdParty_v2.4.1\include\ThirdParty.h'
$thirdPartyHeaderContent = @'
#pragma once
// 親フォルダ名が ThirdParty_v2.4.1 のため、下記の #define (2.0.0) よりフォルダ名 (2.4.1) が優先される
#define THIRDPARTY_VERSION "2.0.0"

namespace ThirdParty {
    void ExecutePlugin();
}
'@
Write-TextFile -Path $thirdPartyHeaderPath -Content $thirdPartyHeaderContent
Write-DummyLib -Path (Join-Path $prodADir 'ThirdParty_v2.4.1\lib\ThirdParty.lib') -LibName 'ThirdParty.lib'

# (d-2) 英字直結フォルダ名にバージョン表記 (Lua5.4.6: 期待抽出値 5.4.6)
$luaHeaderPath = Join-Path $prodADir 'Lua5.4.6\include\Lua.h'
$luaHeaderContent = @'
#pragma once
namespace Lua {
    void OpenLibs();
}
'@
Write-TextFile -Path $luaHeaderPath -Content $luaHeaderContent
Write-DummyLib -Path (Join-Path $prodADir 'Lua5.4.6\lib\Lua.lib') -LibName 'Lua.lib'

# (a-3) 末尾が "ver" のヘッダ名 + "//" 内の "/*" + ネストした "#if 0" ブロック (期待抽出値 2.7.0)
$serverHeaderPath = Join-Path $prodADir 'include\Server.h'
$serverHeaderContent = @'
#pragma once
// パス例: docs/*.h や /* コメント内スラッシュが後続の有効定義を消さないこと
#if 0
#ifdef LEGACY_SERVER_API
#define SERVER_VERSION "0.1.0-nested-disabled"
#endif
#endif

#define SERVER_VERSION "2.7.0"

namespace Server {
    bool Start();
}
'@
Write-TextFile -Path $serverHeaderPath -Content $serverHeaderContent
Write-DummyLib -Path (Join-Path $prodADir 'lib\Server.lib') -LibName 'Server.lib'

# ProjectReference 先のサブプロジェクト (SubCore: 期待抽出値 1.1.0)
$subCoreHeaderPath = Join-Path $prodADir 'SubCore\include\SubCore.h'
$subCoreHeaderContent = @'
#pragma once
#define SUBCORE_VERSION "1.1.0"

namespace SubCore {
    int GetStatus();
}
'@
Write-TextFile -Path $subCoreHeaderPath -Content $subCoreHeaderContent
Write-DummyLib -Path (Join-Path $prodADir 'SubCore\lib\SubCore.lib') -LibName 'SubCore.lib'

$subCoreVcxprojPath = Join-Path $prodADir 'SubCore\SubCore.vcxproj'
$subCoreVcxprojContent = @'
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup Label="Globals">
    <ProjectGuid>{11111111-AAAA-BBBB-CCCC-000000000001}</ProjectGuid>
    <ProjectName>SubCore</ProjectName>
    <ConfigurationType>StaticLibrary</ConfigurationType>
  </PropertyGroup>
  <ItemDefinitionGroup>
    <ClCompile>
      <AdditionalIncludeDirectories>$(ProjectDir)include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ClCompile>
  </ItemDefinitionGroup>
  <ItemGroup>
    <ClInclude Include="include\SubCore.h" />
  </ItemGroup>
</Project>
'@
Write-TextFile -Path $subCoreVcxprojPath -Content $subCoreVcxprojContent

# バイナリ情報(.dll) ＞ フォルダ名 の優先順位検証用:
# フォルダ名は PluginSdk_v1.8.0 だが、DLLバイナリの FileVersion は 1.8.2.0（期待抽出値: 1.8.2.0）
$pluginSdkDllPath = Join-Path $prodADir 'bin\PluginSdk_v1.8.0\PluginSdk.dll'
Write-BinaryDllWithVersion -Path $pluginSdkDllPath -ClassName 'PluginSdk' -FileVersion '1.8.2.0' -ProductVersion '1.8.2'

# (c-5) ヘッダとソースコード双方に 1.○○○△ 形式の改訂履歴があり、ソースコード側が最新となるパターン
# ヘッダ: 1.420N, ソースコード: 1.425P -> 期待抽出値: 1.425P
$histSrcNewerHeaderPath = Join-Path $prodADir 'include\HistDiffSrcNewer.h'
$histSrcNewerHeaderContent = @'
#pragma once
/*
 * 改訂履歴
 * 2025/02/10  1.420N  I/F拡張
 * 2024/11/05  1.410K  初版作成
 */
namespace HistDiffSrcNewer {
    void Execute();
}
'@
$histSrcNewerSourcePath = Join-Path $prodADir 'src\HistDiffSrcNewer.cpp'
$histSrcNewerSourceContent = @'
#include "HistDiffSrcNewer.h"
/*
 * 改訂履歴
 * 2025/05/20  1.425P  内部バッファ処理の不具合修正
 * 2025/02/10  1.420N  I/F拡張
 * 2024/11/05  1.410K  初版作成
 */
namespace HistDiffSrcNewer {
    void Execute() {}
}
'@
Write-TextFile -Path $histSrcNewerHeaderPath -Content $histSrcNewerHeaderContent
Write-TextFile -Path $histSrcNewerSourcePath -Content $histSrcNewerSourceContent
Write-DummyLib -Path (Join-Path $prodADir 'lib\HistDiffSrcNewer.lib') -LibName 'HistDiffSrcNewer.lib'

# (c-6) ヘッダとソースコード双方に 1.○○○△ 形式の改訂履歴があり、ヘッダ側が最新（同数値部＋英文字比較）となるパターン
# ヘッダ(日付なし・昇順): 1.420N -> 1.420P, ソースコード: 1.420M -> 1.420N -> 期待抽出値: 1.420P
$histHdrNewerHeaderPath = Join-Path $prodADir 'include\HistDiffHdrNewer.h'
$histHdrNewerHeaderContent = @'
#pragma once
// 改訂履歴
// 1.420N  初期公開
// 1.420P  APIシグネチャ修正
namespace HistDiffHdrNewer {
    int GetVersionCode();
}
'@
$histHdrNewerSourcePath = Join-Path $prodADir 'src\HistDiffHdrNewer.cpp'
$histHdrNewerSourceContent = @'
#include "HistDiffHdrNewer.h"
// 1.420M  試作
// 1.420N  初期実装
namespace HistDiffHdrNewer {
    int GetVersionCode() { return 1420; }
}
'@
Write-TextFile -Path $histHdrNewerHeaderPath -Content $histHdrNewerHeaderContent
Write-TextFile -Path $histHdrNewerSourcePath -Content $histHdrNewerSourceContent
Write-DummyLib -Path (Join-Path $prodADir 'lib\HistDiffHdrNewer.lib') -LibName 'HistDiffHdrNewer.lib'

# ProductA.vcxproj
$prodAVcxprojPath = Join-Path $prodADir 'ProductA.vcxproj'
$prodAVcxprojContent = @'
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup Label="Globals">
    <ProjectGuid>{AAAAAAAA-0000-1111-2222-333333333333}</ProjectGuid>
    <ProjectName>ProductA</ProjectName>
    <ConfigurationType>Application</ConfigurationType>
  </PropertyGroup>
  <ItemDefinitionGroup Condition="'$(Configuration)|$(Platform)'=='Release|x64'">
    <ClCompile>
      <AdditionalIncludeDirectories>$(ProjectDir)include;$(ProjectDir)ThirdParty_v2.4.1\include;$(ProjectDir)Lua5.4.6\include;$(ProjectDir)SubCore\include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ClCompile>
    <Link>
      <AdditionalLibraryDirectories>$(ProjectDir)lib;$(ProjectDir)ThirdParty_v2.4.1\lib;$(ProjectDir)Lua5.4.6\lib;$(ProjectDir)SubCore\lib;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
      <AdditionalDependencies>AlphaDef.lib;BetaDesc.lib;GammaAsc.lib;ThirdParty.lib;Lua.lib;Server.lib;HistDiffSrcNewer.lib;HistDiffHdrNewer.lib;kernel32.lib;user32.lib;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
  <ItemGroup>
    <ProjectReference Include="SubCore\SubCore.vcxproj">
      <Project>{11111111-AAAA-BBBB-CCCC-000000000001}</Project>
    </ProjectReference>
  </ItemGroup>
  <ItemGroup>
    <Reference Include="PluginSdk">
      <HintPath>bin\PluginSdk_v1.8.0\PluginSdk.dll</HintPath>
    </Reference>
  </ItemGroup>
</Project>
'@
Write-TextFile -Path $prodAVcxprojPath -Content $prodAVcxprojContent

# ProductA の CL.read.1.tlog と link.read.1.tlog
$prodATlogDir = Join-Path $prodADir 'x64\Release\ProductA.tlog'
$prodAClTlogContent = @"
^$($prodADir.ToUpperInvariant())\SRC\MAIN.CPP
C:\PROGRAM FILES\MICROSOFT VISUAL STUDIO\2022\VC\INCLUDE\IOSTREAM
$($alphaHeaderPath.ToUpperInvariant())
$($betaHeaderPath.ToUpperInvariant())
$($gammaHeaderPath.ToUpperInvariant())
$($tlogOnlyHeaderPath.ToUpperInvariant())
$($thirdPartyHeaderPath.ToUpperInvariant())
$($luaHeaderPath.ToUpperInvariant())
$($serverHeaderPath.ToUpperInvariant())
$($subCoreHeaderPath.ToUpperInvariant())
"@
Write-TextFile -Path (Join-Path $prodATlogDir 'CL.read.1.tlog') -Content $prodAClTlogContent -Encoding $utf16Le

$prodALinkTlogContent = @"
^$($prodADir.ToUpperInvariant())\X64\RELEASE\MAIN.OBJ
C:\PROGRAM FILES (X86)\WINDOWS KITS\10\LIB\10.0.22621.0\UM\X64\KERNEL32.LIB
C:\PROGRAM FILES (X86)\WINDOWS KITS\10\LIB\10.0.22621.0\UM\X64\USER32.LIB
$((Join-Path $prodADir 'lib\AlphaDef.lib').ToUpperInvariant())
$((Join-Path $prodADir 'lib\BetaDesc.lib').ToUpperInvariant())
$((Join-Path $prodADir 'lib\GammaAsc.lib').ToUpperInvariant())
$((Join-Path $prodADir 'lib\TlogOnlyLib.lib').ToUpperInvariant())
$((Join-Path $prodADir 'ThirdParty_v2.4.1\lib\ThirdParty.lib').ToUpperInvariant())
$((Join-Path $prodADir 'Lua5.4.6\lib\Lua.lib').ToUpperInvariant())
$((Join-Path $prodADir 'lib\Server.lib').ToUpperInvariant())
$((Join-Path $prodADir 'SubCore\lib\SubCore.lib').ToUpperInvariant())
"@
Write-TextFile -Path (Join-Path $prodATlogDir 'link.read.1.tlog') -Content $prodALinkTlogContent -Encoding $utf16Le


# ==============================================================================
# 2. ProductB の構築 (C++ / .NET 混在構成)
# ==============================================================================
$prodBDir = Join-Path $testEnvRoot 'ProductB'

# (e) バージョン記載なし（タイムスタンプフォールバック確認用: 期待抽出値 2024-08-20 14:30:00）
$deltaTimestamp = Get-Date '2024-08-20 14:30:00'
$deltaHeaderPath = Join-Path $prodBDir 'include\DeltaNoVer.h'
$deltaHeaderContent = @'
#pragma once
#ifndef DELTA_NOVER_H
#define DELTA_NOVER_H

// バージョンに関する #define や改訂履歴コメントが一切存在しないヘッダファイル
namespace Delta {
    void ProcessLegacyData(int mode);
}

#endif // DELTA_NOVER_H
'@
Write-TextFile -Path $deltaHeaderPath -Content $deltaHeaderContent -Timestamp $deltaTimestamp
Write-DummyLib -Path (Join-Path $prodBDir 'lib\DeltaNoVer.lib') -LibName 'DeltaNoVer.lib' -Timestamp $deltaTimestamp

# (c-2) 改訂履歴の昇順・降順が判別できないパターン
# （バージョン番号・日付ともに単調増加でも単調減少でもない → 先頭: 2.1.0 / 末尾: 1.9.0、Status: 要目視確認）
$epsilonHeaderPath = Join-Path $prodBDir 'include\EpsilonAmbiguous.h'
$epsilonHeaderContent = @'
#pragma once
#ifndef EPSILON_AMBIGUOUS_H
#define EPSILON_AMBIGUOUS_H

/*
 * ============================================================================
 * EpsilonAmbiguous Codec Header
 * 改訂履歴 (Revision History) - 昇順・降順が判別不能なケース
 * ----------------------------------------------------------------------------
 * 2025/05/10  Ver 2.1.0  顧客向けカスタムパッチ適用版
 * 2025/08/20  Ver 1.8.0  旧安定版ブランチからのバックポート統合
 * 2025/03/01  Ver 1.9.0  ベースラインリリース
 * ============================================================================
 */

namespace Epsilon {
    int EncodeFrame(const void* src, int size);
}

#endif // EPSILON_AMBIGUOUS_H
'@
Write-TextFile -Path $epsilonHeaderPath -Content $epsilonHeaderContent
Write-DummyLib -Path (Join-Path $prodBDir 'lib\EpsilonAmbiguous.lib') -LibName 'EpsilonAmbiguous.lib'

# (c-3) 改訂履歴の全エントリが同一バージョンのパターン（Status: OK / 期待抽出値: 1.0.0）
$sameVerHeaderPath = Join-Path $prodBDir 'include\SameVerHistory.h'
$sameVerHeaderContent = @'
#pragma once
/*
 * 改訂履歴
 * 2024/01/10 Ver 1.0.0 初版リリース
 * 2024/03/15 Ver 1.0.0 ドキュメントコメント追記
 */
namespace SameVer {
    void Ping();
}
'@
Write-TextFile -Path $sameVerHeaderPath -Content $sameVerHeaderContent
Write-DummyLib -Path (Join-Path $prodBDir 'lib\SameVerHistory.lib') -LibName 'SameVerHistory.lib'

# (c-4) 日付が一部欠落しつつ日付順序がバージョン順序と矛盾するパターン（要目視確認）
$partialDateHeaderPath = Join-Path $prodBDir 'include\PartialDateConflict.h'
$partialDateHeaderContent = @'
#pragma once
/*
 * 改訂履歴
 * 2025/05/01 Ver 2.0.0 機能追加
 * Ver 1.9.0 軽微修正 (日付記載なし)
 * 2025/08/01 Ver 1.8.0 初期統合
 */
namespace PartialDate {
    void Sync();
}
'@
Write-TextFile -Path $partialDateHeaderPath -Content $partialDateHeaderContent
Write-DummyLib -Path (Join-Path $prodBDir 'lib\PartialDateConflict.lib') -LibName 'PartialDateConflict.lib'

# 同一パッケージ内複数ヘッダ + 別プレフィックス分割 #define 混在確認 (期待抽出値: 1.6.3)
$multiPkgDir = Join-Path $prodBDir 'MultiHeaderPkg'
Write-TextFile -Path (Join-Path $multiPkgDir 'include\MultiPkg.h') -Content "#pragma once`nnamespace MultiPkg { void Init(); }`n"
Write-TextFile -Path (Join-Path $multiPkgDir 'include\MultiPkgTypes.h') -Content "#pragma once`ntypedef int MultiPkgHandle;`n"
$multiPkgVerHeaderContent = @'
#pragma once
#define PROTOCOL_MAJOR 9
#define MULTIPKG_MAJOR 1
#define MULTIPKG_MINOR 6
#define MULTIPKG_PATCH 3
'@
Write-TextFile -Path (Join-Path $multiPkgDir 'include\MultiPkgVersion.h') -Content $multiPkgVerHeaderContent
Write-DummyLib -Path (Join-Path $multiPkgDir 'lib\MultiPkg.lib') -LibName 'MultiPkg.lib'

# 中間ビルドフォルダ (obj/) 内のダミーDLL（抽出対象外となることを確認）
Write-DummyDllWithoutVersion -Path (Join-Path $prodBDir 'obj\Debug\net48\IntermediateDummy.dll') -DllName 'IntermediateDummy.dll'

# バイナリ情報ありの .NET DLL (期待抽出値: 3.5.1.0)
$managedCoreDllPath = Join-Path $prodBDir 'bin\ManagedCore.dll'
Write-BinaryDllWithVersion -Path $managedCoreDllPath -ClassName 'ManagedCore' -FileVersion '3.5.1.0' -ProductVersion '3.5.1'

# バイナリ情報なしのダミーネイティブDLL + 対応ヘッダ (#define LEGACY_NATIVE_VERSION "4.0.1" へフォールバック)
$legacyNativeHeaderPath = Join-Path $prodBDir 'include\LegacyNative.h'
$legacyNativeHeaderContent = @'
#pragma once
// DLL側にVS_VERSION_INFOリソースが無い場合、ヘッダの #define から抽出されることを確認
// #define LEGACY_NATIVE_VERSION "3.9.9-old"
#define LEGACY_NATIVE_VERSION "4.0.1"

extern "C" __declspec(dllexport) int LegacyNativeInit();
'@
Write-TextFile -Path $legacyNativeHeaderPath -Content $legacyNativeHeaderContent
$legacyNativeDllPath = Join-Path $prodBDir 'bin\LegacyNative.dll'
Write-DummyDllWithoutVersion -Path $legacyNativeDllPath -DllName 'LegacyNative.dll'

# ProductB.NetUI.csproj (.NET C# プロジェクト)
$prodBCsprojPath = Join-Path $prodBDir 'ProductB.NetUI.csproj'
$prodBCsprojContent = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net48</TargetFramework>
    <OutputType>WinExe</OutputType>
  </PropertyGroup>
  <ItemGroup>
    <Reference Include="ManagedCore">
      <HintPath>bin\ManagedCore.dll</HintPath>
    </Reference>
  </ItemGroup>
</Project>
'@
Write-TextFile -Path $prodBCsprojPath -Content $prodBCsprojContent

# (c-7) ヘッダなし・ソースコードのみに 1.○○○△ 形式の改訂履歴があるパターン（期待抽出値: 1.425P）
$sourceOnlyHistPath = Join-Path $prodBDir 'src\SourceOnlyHist.cpp'
$sourceOnlyHistContent = @'
/*
 * 改訂履歴
 * 2024/09/01  1.420N  ベースライン実装
 * 2025/03/15  1.425P  境界チェック追加
 */
int SourceOnlyHelper() { return 0; }
'@
Write-TextFile -Path $sourceOnlyHistPath -Content $sourceOnlyHistContent
Write-DummyLib -Path (Join-Path $prodBDir 'lib\SourceOnlyHist.lib') -LibName 'SourceOnlyHist.lib'

# ProductB.vcxproj (C++ / .NET 混在プロジェクト)
$prodBVcxprojPath = Join-Path $prodBDir 'ProductB.vcxproj'
$prodBVcxprojContent = @'
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup Label="Globals">
    <ProjectGuid>{BBBBBBBB-0000-1111-2222-333333333333}</ProjectGuid>
    <ProjectName>ProductB</ProjectName>
    <ConfigurationType>DynamicLibrary</ConfigurationType>
    <CLRSupport>true</CLRSupport>
  </PropertyGroup>
  <ItemDefinitionGroup Condition="'$(Configuration)|$(Platform)'=='Release|x64'">
    <ClCompile>
      <AdditionalIncludeDirectories>$(ProjectDir)include;$(ProjectDir)MultiHeaderPkg\include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ClCompile>
    <Link>
      <AdditionalLibraryDirectories>$(ProjectDir)lib;$(ProjectDir)MultiHeaderPkg\lib;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
      <AdditionalDependencies>DeltaNoVer.lib;EpsilonAmbiguous.lib;SameVerHistory.lib;PartialDateConflict.lib;MultiPkg.lib;SourceOnlyHist.lib;advapi32.lib;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
  <ItemGroup>
    <ProjectReference Include="ProductB.NetUI.csproj">
      <Project>{22222222-AAAA-BBBB-CCCC-000000000002}</Project>
    </ProjectReference>
  </ItemGroup>
  <ItemGroup>
    <Reference Include="ManagedCore">
      <HintPath>bin\ManagedCore.dll</HintPath>
    </Reference>
  </ItemGroup>
</Project>
'@
Write-TextFile -Path $prodBVcxprojPath -Content $prodBVcxprojContent

# ProductB の CL.read.1.tlog と link.read.1.tlog
$prodBTlogDir = Join-Path $prodBDir 'x64\Release\ProductB.tlog'
$prodBClTlogContent = @"
^$($prodBDir.ToUpperInvariant())\SRC\BRIDGE.CPP
$($deltaHeaderPath.ToUpperInvariant())
$($epsilonHeaderPath.ToUpperInvariant())
$($legacyNativeHeaderPath.ToUpperInvariant())
"@
Write-TextFile -Path (Join-Path $prodBTlogDir 'CL.read.1.tlog') -Content $prodBClTlogContent -Encoding $utf16Le

$prodBLinkTlogContent = @"
^$($prodBDir.ToUpperInvariant())\X64\RELEASE\BRIDGE.OBJ
C:\PROGRAM FILES (X86)\WINDOWS KITS\10\LIB\10.0.22621.0\UM\X64\ADVAPI32.LIB
$((Join-Path $prodBDir 'lib\DeltaNoVer.lib').ToUpperInvariant())
$((Join-Path $prodBDir 'lib\EpsilonAmbiguous.lib').ToUpperInvariant())
"@
Write-TextFile -Path (Join-Path $prodBTlogDir 'link.read.1.tlog') -Content $prodBLinkTlogContent -Encoding $utf16Le

Write-Host "テスト用ダミー環境を構築しました: $testEnvRoot" -ForegroundColor Green
