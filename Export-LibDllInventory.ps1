<#
.SYNOPSIS
    Windowsアプリ（C++ / .NET混在想定）の製品フォルダ配下から、依存している .lib / .dll と各バージョンを
    ルールベース（正規表現＋メタデータ）で機械的に抽出し、UTF-8 (BOM付き) CSV に出力します。

.DESCRIPTION
    【バージョン抽出の優先順位】
      1. バイナリ情報 (.dll の FileVersion / ProductVersion)
      2. フォルダ名 (例: ThirdParty_v2.4.1, Lua5.4.6)
      3. #define (対応するヘッダ / ソースファイル内の有効なマクロ定義。コメントアウトや #if 0 は除外)
      4. 改訂履歴コメント (対応するヘッダ / ソースファイル内の履歴コメント。昇順・降順を自動判定)
         ※数値＋英文字表記 (例: 1.420N < 1.425P) に対応し、複数ファイル間で最新のバージョンを採用
         ※昇順・降順が判別できない場合は「先頭: X.X.X / 末尾: Y.Y.Y」を出力し、Status列を「要目視確認」に設定
      5. 更新日時 (対象ファイルの LastWriteTime にフォールバック)

    【依存関係の検出元】
      - .vcxproj (AdditionalDependencies, ProjectReference, Reference, AdditionalIncludeDirectories, AdditionalLibraryDirectories)
      - .csproj (Reference, ProjectReference)
      - link.read.*.tlog / CL.read.*.tlog
      - 製品フォルダ配下のファイルシステム探索 (.lib / .dll。obj/.vs/.git/TestResults/ipch 等の中間フォルダは除外)

.PARAMETER RootPath
    製品サブフォルダ (ProductA, ProductB 等) を格納したルートフォルダパス。既定値は ./test_env。

.PARAMETER OutputCsvPath
    出力先CSVファイルパス。既定値は ./LibDllInventory.csv。UTF-8 (BOM付き) で出力されます。

.PARAMETER IncludeSystemLibs
    kernel32.lib 等の Windows 標準 SDK ライブラリも出力に含める場合に指定します。

.PARAMETER PassThru
    抽出結果オブジェクトをパイプラインにも出力する場合に指定します。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RootPath = (Join-Path $PSScriptRoot 'test_env'),

    [Parameter(Mandatory = $false)]
    [string]$OutputCsvPath = (Join-Path $PSScriptRoot 'LibDllInventory.csv'),

    [Parameter(Mandatory = $false)]
    [switch]$IncludeSystemLibs,

    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows SDK / CRT の標準ライブラリ一覧（既定で除外）
$StandardSystemLibs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@(
    'kernel32.lib', 'user32.lib', 'gdi32.lib', 'winspool.lib', 'comdlg32.lib',
    'advapi32.lib', 'shell32.lib', 'ole32.lib', 'oleaut32.lib', 'uuid.lib',
    'odbc32.lib', 'odbccp32.lib', 'ws2_32.lib', 'wininet.lib', 'winhttp.lib',
    'crypt32.lib', 'bcrypt.lib', 'ncrypt.lib', 'shlwapi.lib', 'version.lib',
    'imm32.lib', 'msimg32.lib', 'setupapi.lib', 'cfgmgr32.lib', 'propsys.lib',
    'dwmapi.lib', 'uxtheme.lib', 'gdiplus.lib', 'comctl32.lib', 'mpr.lib',
    'netapi32.lib', 'userenv.lib', 'wtsapi32.lib', 'psapi.lib', 'dbghelp.lib',
    'iphlpapi.lib', 'secur32.lib', 'oleacc.lib', 'msvcrt.lib', 'msvcrtd.lib',
    'libcmt.lib', 'libcmtd.lib', 'vcruntime.lib', 'vcruntimed.lib',
    'ucrt.lib', 'ucrtd.lib', 'msvcprt.lib', 'msvcprtd.lib'
) | ForEach-Object { [void]$StandardSystemLibs.Add($_) }

# ファイルシステム走査から除外する中間ビルド・IDE管理フォルダ
$ExcludedDirRegex = '(?:^|[\\/])(?:obj|\.vs|\.git|TestResults|ipch)(?:[\\/]|$)'

function Test-IsExcludedPath {
    param(
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)][string]$BaseDir
    )
    $rel = Get-NormalizedRelativePath -BasePath $BaseDir -TargetPath $FullPath
    return ($rel -match $ExcludedDirRegex)
}

function Get-NormalizedRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )
    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    if ($targetFull.StartsWith($baseFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $targetFull.Substring($baseFull.Length + 1)
    }
    return $targetFull
}

function Expand-MsBuildPath {
    param(
        [Parameter(Mandatory = $true)][string]$RawPath,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$ProductDir
    )
    $projDirSlash = $ProjectDir.TrimEnd('\', '/') + '\'
    $prodDirSlash = $ProductDir.TrimEnd('\', '/') + '\'

    $expanded = $RawPath.Trim()
    $expanded = $expanded -ireplace '\$\(ProjectDir\)', $projDirSlash
    $expanded = $expanded -ireplace '\$\(MSBuildProjectDirectory\)', $ProjectDir.TrimEnd('\', '/')
    $expanded = $expanded -ireplace '\$\(SolutionDir\)', $prodDirSlash

    # 相対パスの場合は ProjectDir 基準で解決
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $ProjectDir $expanded
    }
    try {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        return $expanded
    }
}

function Read-TextAutoEncoding {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath
    )
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    if ($bytes.Length -ge 2) {
        # UTF-16 LE BOM
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        }
        # UTF-16 BE BOM
        if ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
        }
    }
    if ($bytes.Length -ge 3) {
        # UTF-8 BOM
        if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        }
    }
    # UTF-8 として妥当か検証し、不正バイトがあれば CP932 (Shift-JIS) として読み込む
    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        return $utf8Strict.GetString($bytes)
    }
    catch {
        return [System.Text.Encoding]::GetEncoding(932).GetString($bytes)
    }
}

function ConvertTo-VersionKey {
    <#
    .SYNOPSIS
        バージョン文字列を比較可能な構造 (数値4要素 + 英文字サフィックス + プレリリース部) に分解します。
        例: "1.420N" -> Tuple=@(1, 420, 0, 0), AlphaSuffix="N"
    #>
    param([Parameter(Mandatory = $true)][string]$VersionString)

    $clean = $VersionString.Trim() -replace '^[^\d]+', ''
    $tuple = @(0, 0, 0, 0)
    $alphaSuffix = ''
    $preRelease  = ''

    if ($clean -match '^(?<nums>\d+(?:\.\d+){0,3})(?<alpha>[A-Za-z]+)?(?<pre>-[0-9A-Za-z\._]+)?') {
        $parts = $Matches['nums'] -split '\.'
        for ($i = 0; $i -lt [Math]::Min($parts.Count, 4); $i++) {
            $val = 0
            if ([int]::TryParse($parts[$i], [ref]$val)) {
                $tuple[$i] = $val
            }
        }
        if ($Matches['alpha']) { $alphaSuffix = $Matches['alpha'] }
        if ($Matches['pre'])   { $preRelease  = $Matches['pre'] }
    }

    return [PSCustomObject]@{
        Tuple       = $tuple
        AlphaSuffix = $alphaSuffix
        PreRelease  = $preRelease
    }
}

function Compare-VersionKey {
    <#
    .SYNOPSIS
        2つのバージョンキーを比較します (-1: A < B, 0: A == B, 1: A > B)。
        数値部 -> 英文字サフィックス (1.420N < 1.420P) -> プレリリース部の順に比較します。
    #>
    param(
        [Parameter(Mandatory = $true)]$KeyA,
        [Parameter(Mandatory = $true)]$KeyB
    )

    for ($i = 0; $i -lt 4; $i++) {
        if ($KeyA.Tuple[$i] -lt $KeyB.Tuple[$i]) { return -1 }
        if ($KeyA.Tuple[$i] -gt $KeyB.Tuple[$i]) { return 1 }
    }

    $hasAlphaA = -not [string]::IsNullOrEmpty($KeyA.AlphaSuffix)
    $hasAlphaB = -not [string]::IsNullOrEmpty($KeyB.AlphaSuffix)
    if (-not $hasAlphaA -and $hasAlphaB) { return -1 }
    if ($hasAlphaA -and -not $hasAlphaB) { return 1 }
    if ($hasAlphaA -and $hasAlphaB) {
        $uA = $KeyA.AlphaSuffix.ToUpperInvariant()
        $uB = $KeyB.AlphaSuffix.ToUpperInvariant()
        if ($uA.Length -lt $uB.Length) { return -1 }
        if ($uA.Length -gt $uB.Length) { return 1 }
        $cmpAlpha = [string]::CompareOrdinal($uA, $uB)
        if ($cmpAlpha -ne 0) { return $(if ($cmpAlpha -lt 0) { -1 } else { 1 }) }

        $cmpExact = [string]::CompareOrdinal($KeyA.AlphaSuffix, $KeyB.AlphaSuffix)
        if ($cmpExact -ne 0) { return $(if ($cmpExact -lt 0) { -1 } else { 1 }) }
    }

    $hasPreA = -not [string]::IsNullOrEmpty($KeyA.PreRelease)
    $hasPreB = -not [string]::IsNullOrEmpty($KeyB.PreRelease)
    if ($hasPreA -and -not $hasPreB) { return -1 }
    if (-not $hasPreA -and $hasPreB) { return 1 }
    if ($hasPreA -and $hasPreB) {
        $cmpPre = [string]::Compare($KeyA.PreRelease, $KeyB.PreRelease, [System.StringComparison]::OrdinalIgnoreCase)
        if ($cmpPre -ne 0) { return $(if ($cmpPre -lt 0) { -1 } else { 1 }) }
    }

    return 0
}

function Remove-CppCommentsAndDisabledIf0 {
    param([Parameter(Mandatory = $true)][string]$SourceText)

    # 1. 文字列リテラル・文字リテラルを保護しつつ // コメントと /* */ コメントを1パスで除去
    #    (// 行内の /* が誤ってブロックコメントを開始するのを防ぐ)
    $tokenRegex = '(?s)"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|//(?:\\\r?\n|[^\r\n])*|/\*.*?\*/'
    $noComments = [regex]::Replace($SourceText, $tokenRegex, {
        param($m)
        $val = $m.Value
        if ($val.StartsWith('//') -or $val.StartsWith('/*')) {
            return ($val -replace '[^\r\n]', ' ')
        }
        return $val
    })

    # 2. #if 0 ... #endif 無効化ブロックをネスト深さ・#else を考慮して除去
    $lines = $noComments -split '\r?\n'
    $keptLines = New-Object System.Collections.Generic.List[string]
    # 各 #if 階層のアクティブ状態スタック (true = 有効, false = #if 0 等で無効)
    $ifStack = New-Object System.Collections.Generic.Stack[PSCustomObject]

    function Test-IsCurrentlyActive {
        param($Stack)
        foreach ($frame in $Stack) {
            if (-not $frame.BranchActive) { return $false }
        }
        return $true
    }

    foreach ($line in $lines) {
        if ($line -match '^\s*#\s*if\s+\(?\s*0\s*\)?(?:\s|$)') {
            $ifStack.Push([PSCustomObject]@{ BranchActive = $false; SeenTrue = $false })
            continue
        }
        elseif ($line -match '^\s*#\s*if(?:def|ndef)?\b') {
            $ifStack.Push([PSCustomObject]@{ BranchActive = $true; SeenTrue = $true })
            if (Test-IsCurrentlyActive -Stack $ifStack) {
                $keptLines.Add($line)
            }
            continue
        }
        elseif ($line -match '^\s*#\s*elif\b') {
            if ($ifStack.Count -gt 0) {
                $top = $ifStack.Peek()
                if ($top.SeenTrue) {
                    $top.BranchActive = $false
                }
                elseif ($line -match '^\s*#\s*elif\s+\(?\s*0\s*\)?(?:\s|$)') {
                    $top.BranchActive = $false
                }
                else {
                    $top.BranchActive = $true
                    $top.SeenTrue = $true
                }
            }
            continue
        }
        elseif ($line -match '^\s*#\s*else\b') {
            if ($ifStack.Count -gt 0) {
                $top = $ifStack.Peek()
                if ($top.SeenTrue) {
                    $top.BranchActive = $false
                }
                else {
                    $top.BranchActive = $true
                    $top.SeenTrue = $true
                }
            }
            continue
        }
        elseif ($line -match '^\s*#\s*endif\b') {
            $wasActive = Test-IsCurrentlyActive -Stack $ifStack
            if ($ifStack.Count -gt 0) {
                [void]$ifStack.Pop()
            }
            if ($wasActive) {
                $keptLines.Add($line)
            }
            continue
        }

        if (Test-IsCurrentlyActive -Stack $ifStack) {
            $keptLines.Add($line)
        }
    }

    return ($keptLines -join "`n")
}

function Get-BinaryDllVersion {
    param([Parameter(Mandatory = $true)][string]$DllPath)
    if (-not (Test-Path -LiteralPath $DllPath)) {
        return $null
    }
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($DllPath)
        foreach ($candidate in @($vi.FileVersion, $vi.ProductVersion)) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $trimmed = $candidate.Trim()
                # ドット区切り (1.8.2.0) またはネイティブRCのカンマ区切り ("1, 8, 2, 0") の両方を抽出
                if ($trimmed -match '(?<ver>\d+(?:\s*[\.,]\s*\d+){1,3}(?:-[0-9A-Za-z\.]+)?)') {
                    $normVer = ($Matches['ver'] -replace '\s*,\s*', '.').Trim()
                    if ($normVer -notmatch '^0(?:\.0){1,3}$') {
                        return [PSCustomObject]@{
                            Version       = $normVer
                            VersionSource = 'バイナリ情報(.dll)'
                            Status        = 'OK'
                            Notes         = "DLLメタデータ (FileVersion: $($vi.FileVersion), ProductVersion: $($vi.ProductVersion))"
                        }
                    }
                }
            }
        }

        # 文字列表記が空でも数値パートが設定されている場合へのフォールバック
        if ($vi.FileMajorPart -gt 0 -or $vi.FileMinorPart -gt 0 -or $vi.FileBuildPart -gt 0 -or $vi.FilePrivatePart -gt 0) {
            $numVer = "$($vi.FileMajorPart).$($vi.FileMinorPart).$($vi.FileBuildPart).$($vi.FilePrivatePart)"
            return [PSCustomObject]@{
                Version       = $numVer
                VersionSource = 'バイナリ情報(.dll)'
                Status        = 'OK'
                Notes         = "DLLメタデータ数値部 (FileVersionPart: $numVer)"
            }
        }
        if ($vi.ProductMajorPart -gt 0 -or $vi.ProductMinorPart -gt 0 -or $vi.ProductBuildPart -gt 0 -or $vi.ProductPrivatePart -gt 0) {
            $numVer = "$($vi.ProductMajorPart).$($vi.ProductMinorPart).$($vi.ProductBuildPart).$($vi.ProductPrivatePart)"
            return [PSCustomObject]@{
                Version       = $numVer
                VersionSource = 'バイナリ情報(.dll)'
                Status        = 'OK'
                Notes         = "DLLメタデータ数値部 (ProductVersionPart: $numVer)"
            }
        }
    }
    catch {
        return $null
    }
    return $null
}

function Get-FolderVersion {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$TargetPaths,
        [Parameter(Mandatory = $true)][string]$ProductDir,
        [string]$RootDir
    )
    $productFull = [System.IO.Path]::GetFullPath($ProductDir).TrimEnd('\', '/')
    $rootFull    = if (-not [string]::IsNullOrWhiteSpace($RootDir)) {
        [System.IO.Path]::GetFullPath($RootDir).TrimEnd('\', '/')
    } else { $productFull }

    # TargetFramework名などはフォルダバージョン表記から除外
    $ignoreDirRegex = '^(?i)(?:x64|x86|win32|win64|arm64|debug|release|bin|lib|include|src|obj|net\d+(?:\.\d+)?|netstandard\d+\.\d+|netcoreapp\d+\.\d+|.*\.tlog)$'

    foreach ($tPath in $TargetPaths) {
        if ([string]::IsNullOrWhiteSpace($tPath)) { continue }
        $fullTPath = [System.IO.Path]::GetFullPath($tPath)
        $currentDir = Split-Path -Path $fullTPath -Parent

        # 走査上限を決定:
        # 1) 製品フォルダ内なら製品フォルダの手前まで
        # 2) 製品フォルダ外かつ RootDir 内なら RootDir の手前まで (例: ..\Shared\OpenSSL_v3.1.4)
        # 3) RootDir 外なら親ディレクトリ最大3階層まで
        $isInsideProduct = $fullTPath.StartsWith($productFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
        $isInsideRoot    = $fullTPath.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
        $maxExternalDepth = 3
        $depth = 0

        while (-not [string]::IsNullOrWhiteSpace($currentDir)) {
            if ($isInsideProduct) {
                if ($currentDir.Length -le $productFull.Length -or -not $currentDir.StartsWith($productFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                    break
                }
            }
            elseif ($isInsideRoot) {
                if ($currentDir.Length -le $rootFull.Length -or -not $currentDir.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                    break
                }
            }
            else {
                if ($depth -ge $maxExternalDepth) { break }
                $depth++
            }

            $dirName = Split-Path -Path $currentDir -Leaf
            if (-not [string]::IsNullOrWhiteSpace($dirName) -and $dirName -notmatch $ignoreDirRegex) {
                # パターン1: ドット区切りバージョン (例: ThirdParty_v2.4.1, Lua5.4.6, Sdk-1.2.3-rc1, Ver2.0.5)
                # ※ (?<!\d\.) により Lua5.4.6 の途中の ".4.6" へ誤マッチすることを防止
                if ($dirName -match '(?i)(?:^|[_\-\.\s]|ver|version|v|(?<=[A-Za-z]))(?<!\d\.)(?<ver>\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z\.]+)?)(?:$|[_\-\s])') {
                    return [PSCustomObject]@{
                        Version       = $Matches['ver']
                        VersionSource = 'フォルダ名'
                        Status        = 'OK'
                        Notes         = "フォルダ名 '$dirName' から抽出"
                    }
                }
                # パターン2: アンダースコア区切りバージョン (例: boost_1_82_0, boost1_82_0, Lib_v2_4_1)
                if ($dirName -match '(?i)(?:^|[_\-\s]|(?<=[A-Za-z]))(?<!\d_)v?(?<ver>\d+_\d+_\d+(?:_\d+)?)(?:$|[_\-\s])') {
                    $verDot = $Matches['ver'] -replace '_', '.'
                    return [PSCustomObject]@{
                        Version       = $verDot
                        VersionSource = 'フォルダ名'
                        Status        = 'OK'
                        Notes         = "フォルダ名 '$dirName' から抽出"
                    }
                }
            }
            $currentDir = Split-Path -Path $currentDir -Parent
        }
    }
    return $null
}

function Get-CodeDefineVersion {
    param([Parameter(Mandatory = $true)][string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return $null
    }
    $rawContent = Read-TextAutoEncoding -FilePath $FilePath
    $fileLeaf   = Split-Path -Path $FilePath -Leaf
    $cleaned    = Remove-CppCommentsAndDisabledIf0 -SourceText $rawContent

    # パターンA: 単一マクロによるバージョン文字列/数値定義 (例: #define ALPHA_VERSION "1.4.2", "1.425P")
    $singleRegex = '(?im)^\s*#\s*define\s+(?<macro>[A-Za-z_][A-Za-z0-9_]*(?:VER|VERSION|RELEASE)[A-Za-z0-9_]*)\s+["'']?v?(?<ver>\d+\.\d+(?:\.\d+){0,2}(?:[A-Za-z]+)?(?:-[0-9A-Za-z\._]+)?)["'']?(?:\s|$)'
    $mSingle = [regex]::Match($cleaned, $singleRegex)
    if ($mSingle.Success) {
        return [PSCustomObject]@{
            Version       = $mSingle.Groups['ver'].Value
            VersionSource = '#define'
            Status        = 'OK'
            SourceFile    = $FilePath
            Notes         = "#define $($mSingle.Groups['macro'].Value) ($fileLeaf)"
        }
    }

    # パターンB: MAJOR / MINOR / (PATCH|BUILD|REVISION|MICRO|SUBMINOR) 分割マクロ定義
    # 同一プレフィックスを持つマクロ群同士のみを結合する
    $majorMatches = [regex]::Matches($cleaned, '(?im)^\s*#\s*define\s+(?<prefix>[A-Za-z_][A-Za-z0-9_]*)_MAJOR\s+\(?(?<val>\d+)\)?\b')
    foreach ($mMajor in $majorMatches) {
        $prefix = $mMajor.Groups['prefix'].Value
        $escapedPrefix = [regex]::Escape($prefix)
        $mMinor = [regex]::Match($cleaned, "(?im)^\s*#\s*define\s+${escapedPrefix}_MINOR\s+\(?(?<val>\d+)\)?\b")
        if ($mMinor.Success) {
            $verStr = "$($mMajor.Groups['val'].Value).$($mMinor.Groups['val'].Value)"
            $mPatch = [regex]::Match($cleaned, "(?im)^\s*#\s*define\s+${escapedPrefix}_(?:PATCH|BUILD|REVISION|MICRO|SUBMINOR)\s+\(?(?<val>\d+)\)?\b")
            if ($mPatch.Success) {
                $verStr += ".$($mPatch.Groups['val'].Value)"
            }
            return [PSCustomObject]@{
                Version       = $verStr
                VersionSource = '#define'
                Status        = 'OK'
                SourceFile    = $FilePath
                Notes         = "#define ${prefix}_MAJOR 他 ($fileLeaf)"
            }
        }
    }

    return $null
}

function Get-CodeHistoryVersion {
    param([Parameter(Mandatory = $true)][string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return $null
    }
    $rawContent = Read-TextAutoEncoding -FilePath $FilePath
    $fileLeaf   = Split-Path -Path $FilePath -Leaf

    # 文字列リテラルをスキップしつつ、連続するコメントブロック単位で抽出
    $tokenRegex = '(?s)"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|(?://(?:\\\r?\n|[^\r\n])*(?:\r?\n\s*//(?:\\\r?\n|[^\r\n])*)*)|/\*.*?\*/'
    $tokenMatches = [regex]::Matches($rawContent, $tokenRegex)

    $commentBlocks = New-Object System.Collections.Generic.List[string]
    foreach ($tm in $tokenMatches) {
        if ($tm.Value.StartsWith('//') -or $tm.Value.StartsWith('/*')) {
            $commentBlocks.Add($tm.Value)
        }
    }
    if ($commentBlocks.Count -eq 0) {
        return $null
    }

    $datePattern           = '(?<date>(?:19|20)\d{2}[/\-\.](?:0?[1-9]|1[0-2])[/\-\.](?:0?[1-9]|[12]\d|3[01]))'
    $verWithPrefixPattern  = '(?:(?:^|[^A-Za-z0-9_])(?:Ver\.?|Version|Rev\.?|v|V)|版)\s*:?\s*(?<ver>\d+\.\d+(?:\.\d+){0,2}(?:[A-Za-z]+)?(?:-[0-9A-Za-z\.]+)?)(?![A-Za-z0-9_])'
    $verBarePattern        = '(?<![A-Za-z0-9_.])(?<ver>\d+\.\d+(?:\.\d+){0,2}(?:[A-Za-z]+)?(?:-[0-9A-Za-z\.]+)?)(?![A-Za-z0-9_.])'
    $verAlphaStrictPattern = '(?<![A-Za-z0-9_.])(?<ver>\d+\.\d{2,}[A-Z]+)(?![A-Za-z0-9_.])'
    $verAlphaBlockPattern  = '(?<![A-Za-z0-9_.])(?<ver>\d+\.\d+[A-Za-z]+)(?![A-Za-z0-9_.])'
    $historyKeywordPattern = '(?i)(?:改訂|変更|更新|履歴|History|Change\s*Log|Changelog|Revision)'

    function Parse-HistoryEntriesFromText {
        param(
            [string]$BlockText,
            [bool]$IsHistoryKeywordBlock = $false
        )
        $list = New-Object System.Collections.Generic.List[PSCustomObject]
        foreach ($line in ($BlockText -split '\r?\n')) {
            $hasDate = $line -match $datePattern
            $parsedDate = $null
            if ($hasDate) {
                $rawDateStr = ($Matches['date'] -replace '\.', '/')
                $dtTemp = [datetime]::MinValue
                if ([datetime]::TryParse($rawDateStr, [ref]$dtTemp)) {
                    $parsedDate = $dtTemp
                }
            }

            $extractedVer = $null
            $mPrefix = [regex]::Match($line, $verWithPrefixPattern)
            $mAlphaStrict = [regex]::Match($line, $verAlphaStrictPattern)

            if ($mPrefix.Success -and (-not $mAlphaStrict.Success -or $mPrefix.Index -le $mAlphaStrict.Index)) {
                $extractedVer = $mPrefix.Groups['ver'].Value
            }
            elseif ($hasDate) {
                $lineWithoutDate = $line -replace $datePattern, ''
                if ($lineWithoutDate -match $verBarePattern) {
                    $extractedVer = $Matches['ver']
                }
            }
            elseif ($IsHistoryKeywordBlock -and $line -match $verAlphaBlockPattern) {
                $extractedVer = $Matches['ver']
            }
            elseif ($mAlphaStrict.Success) {
                $extractedVer = $mAlphaStrict.Groups['ver'].Value
            }

            if ($null -ne $extractedVer) {
                $list.Add([PSCustomObject]@{
                    RawVersion = $extractedVer
                    VersionKey = (ConvertTo-VersionKey -VersionString $extractedVer)
                    Date       = $parsedDate
                    Line       = $line.Trim()
                })
            }
        }
        return $list
    }

    # ブロック単位で履歴を解析し、専用履歴ブロック（2件以上、または履歴キーワード付き）を優先選択
    # これによりファイル後半の関数コメント ("// Added in v1.0") との混在を防止する
    $bestBlockEntries = $null
    $bestBlockScore   = -1
    $allEntries       = New-Object System.Collections.Generic.List[PSCustomObject]

    foreach ($blk in $commentBlocks) {
        $hasKeyword = ($blk -match $historyKeywordPattern)
        $blkEntries = @(Parse-HistoryEntriesFromText -BlockText $blk -IsHistoryKeywordBlock $hasKeyword)
        foreach ($e in $blkEntries) {
            $allEntries.Add($e)
        }
        if ($blkEntries.Count -ge 2 -or ($blkEntries.Count -ge 1 -and $hasKeyword)) {
            $score = $blkEntries.Count * 10 + $(if ($hasKeyword) { 5 } else { 0 })
            if ($score -gt $bestBlockScore) {
                $bestBlockScore   = $score
                $bestBlockEntries = $blkEntries
            }
        }
    }

    $entries = @(if ($null -ne $bestBlockEntries) { $bestBlockEntries } else { $allEntries })

    if ($entries.Count -eq 0) {
        return $null
    }
    if ($entries.Count -eq 1) {
        return [PSCustomObject]@{
            Version       = $entries[0].RawVersion
            VersionSource = '改訂履歴コメント'
            Status        = 'OK'
            SourceFile    = $FilePath
            Notes         = "改訂履歴1件のみ ($fileLeaf)"
        }
    }

    # 複数履歴がある場合：昇順（下が最新）か降順（上が最新）かを判定
    $verNonDecreasing = $true
    $verNonIncreasing = $true
    $verHasStrictDiff = $false

    for ($i = 0; $i -lt ($entries.Count - 1); $i++) {
        $cmpVer = Compare-VersionKey -KeyA $entries[$i].VersionKey -KeyB $entries[$i + 1].VersionKey
        if ($cmpVer -lt 0) {
            $verNonIncreasing = $false
            $verHasStrictDiff = $true
        }
        elseif ($cmpVer -gt 0) {
            $verNonDecreasing = $false
            $verHasStrictDiff = $true
        }
    }

    # 日付のある行（一部欠落を含む）同士で日付順序の単調性を判定
    $datedEntries = @($entries | Where-Object { $null -ne $_.Date })
    $hasEnoughDates    = $datedEntries.Count -ge 2
    $dateNonDecreasing = $true
    $dateNonIncreasing = $true
    $dateHasStrictDiff = $false

    if ($hasEnoughDates) {
        for ($i = 0; $i -lt ($datedEntries.Count - 1); $i++) {
            if ($datedEntries[$i].Date -lt $datedEntries[$i + 1].Date) {
                $dateNonIncreasing = $false
                $dateHasStrictDiff = $true
            }
            elseif ($datedEntries[$i].Date -gt $datedEntries[$i + 1].Date) {
                $dateNonDecreasing = $false
                $dateHasStrictDiff = $true
            }
        }
    }

    $verIsAsc  = $verNonDecreasing -and $verHasStrictDiff
    $verIsDesc = $verNonIncreasing -and $verHasStrictDiff
    $verAllEq  = $verNonDecreasing -and $verNonIncreasing

    $dateIsAsc    = $hasEnoughDates -and $dateNonDecreasing -and $dateHasStrictDiff
    $dateIsDesc   = $hasEnoughDates -and $dateNonIncreasing -and $dateHasStrictDiff
    $dateAllEq    = $hasEnoughDates -and $dateNonDecreasing -and $dateNonIncreasing
    $dateConflict = $hasEnoughDates -and (-not $dateNonDecreasing) -and (-not $dateNonIncreasing)

    $firstVer = $entries[0].RawVersion
    $lastVer  = $entries[$entries.Count - 1].RawVersion

    # 日付とバージョンが矛盾しないか、全行同一かを判定
    if ($dateConflict) {
        $isAscending  = $false
        $isDescending = $false
    }
    elseif ($verAllEq) {
        # 全履歴行のバージョンが同一の場合（日付矛盾もなければ一意に確定）
        return [PSCustomObject]@{
            Version       = $firstVer
            VersionSource = '改訂履歴コメント'
            Status        = 'OK'
            SourceFile    = $FilePath
            Notes         = "改訂履歴内のバージョンがすべて同一 (全$($entries.Count)件: $firstVer) [$fileLeaf]"
        }
    }
    else {
        $isAscending  = $verIsAsc  -and (-not $hasEnoughDates -or $dateIsAsc  -or $dateAllEq)
        $isDescending = $verIsDesc -and (-not $hasEnoughDates -or $dateIsDesc -or $dateAllEq)
    }

    if ($isDescending -and -not $isAscending) {
        return [PSCustomObject]@{
            Version       = $firstVer
            VersionSource = '改訂履歴コメント(降順)'
            Status        = 'OK'
            SourceFile    = $FilePath
            Notes         = "改訂履歴先頭を採用 (全$($entries.Count)件: 先頭=$firstVer, 末尾=$lastVer) [$fileLeaf]"
        }
    }
    elseif ($isAscending -and -not $isDescending) {
        return [PSCustomObject]@{
            Version       = $lastVer
            VersionSource = '改訂履歴コメント(昇順)'
            Status        = 'OK'
            SourceFile    = $FilePath
            Notes         = "改訂履歴末尾を採用 (全$($entries.Count)件: 先頭=$firstVer, 末尾=$lastVer) [$fileLeaf]"
        }
    }
    else {
        return [PSCustomObject]@{
            Version       = "先頭: $firstVer / 末尾: $lastVer"
            VersionSource = '改訂履歴コメント(順序不明)'
            Status        = '要目視確認'
            SourceFile    = $FilePath
            Notes         = "履歴の昇順・降順が判別不能なため先頭と末尾を併記 (全$($entries.Count)件) [$fileLeaf]"
        }
    }
}

function Select-LatestVersionResult {
    <#
    .SYNOPSIS
        複数のヘッダ／ソースファイルから抽出したバージョン候補を比較し、最新のバージョンを採用します。
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Candidates
    )
    if ($Candidates.Count -eq 0) {
        return $null
    }
    if ($Candidates.Count -eq 1) {
        return $Candidates[0]
    }

    $okResults    = @($Candidates | Where-Object { $_.Status -eq 'OK' })
    $ambigResults = @($Candidates | Where-Object { $_.Status -ne 'OK' })

    if ($okResults.Count -eq 0) {
        return $ambigResults[0]
    }

    $best = $okResults[0]
    $bestKey = ConvertTo-VersionKey -VersionString $best.Version
    for ($i = 1; $i -lt $okResults.Count; $i++) {
        $candKey = ConvertTo-VersionKey -VersionString $okResults[$i].Version
        if ((Compare-VersionKey -KeyA $candKey -KeyB $bestKey) -gt 0) {
            $best    = $okResults[$i]
            $bestKey = $candKey
        }
    }

    $detailParts = New-Object System.Collections.Generic.List[string]
    $distinctVers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $Candidates) {
        $leaf = Split-Path -Path $c.SourceFile -Leaf
        $detailParts.Add("${leaf}=$($c.Version)")
        if ($c.Status -eq 'OK') {
            [void]$distinctVers.Add($c.Version)
        }
    }
    $detailSummary = $detailParts -join ', '
    $bestLeaf = Split-Path -Path $best.SourceFile -Leaf

    if ($ambigResults.Count -gt 0) {
        return [PSCustomObject]@{
            Version       = $best.Version
            VersionSource = $best.VersionSource
            Status        = '要目視確認'
            SourceFile    = $best.SourceFile
            Notes         = "一部ファイルの改訂履歴が順序不明のため要確認; 有効側の最新=${bestLeaf}($($best.Version)) [$detailSummary]"
        }
    }

    $noteText = if ($distinctVers.Count -gt 1) {
        "複数ファイルのバージョンを比較し最新を採用: ${bestLeaf}=$($best.Version) [$detailSummary]"
    } else {
        "複数ファイルでバージョン一致: $($best.Version) [$detailSummary]"
    }

    return [PSCustomObject]@{
        Version       = $best.Version
        VersionSource = $best.VersionSource
        Status        = 'OK'
        SourceFile    = $best.SourceFile
        Notes         = $noteText
    }
}

function Find-AssociatedCodeFiles {
    <#
    .SYNOPSIS
        依存ライブラリに対応するヘッダファイル (.h/.hpp/.hxx) およびソースファイル (.c/.cpp/.cxx/.cc) を探索します。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DepFileName,
        [string]$DepFullPath,
        [Parameter(Mandatory = $true)][string]$ProductDir,
        [AllowEmptyCollection()][string[]]$TlogHeaders = @(),
        [AllowEmptyCollection()][string[]]$IncludeDirHeaders = @(),
        [AllowEmptyCollection()][string[]]$AllProductHeaders = @(),
        [AllowEmptyCollection()][string[]]$AllProductSources = @(),
        [hashtable]$ProjectCodeFilesByStem = @{}
    )
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($DepFileName)
    $normName = $baseName -ireplace '^lib(?=[A-Za-z])', ''
    $normName = $normName -ireplace '(?:_d|_debug|_release|_x64|_x86|_static|_dll)$', ''

    $headers     = New-Object System.Collections.Generic.List[string]
    $sources     = New-Object System.Collections.Generic.List[string]
    $seenHeaders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    function Add-MatchedFile {
        param(
            [string]$PathToAdd,
            [string]$Kind
        )
        if ([string]::IsNullOrWhiteSpace($PathToAdd)) { return }
        if ($Kind -eq 'Header') {
            if ($seenHeaders.Add($PathToAdd)) { $headers.Add($PathToAdd) }
        }
        else {
            if ($seenSources.Add($PathToAdd)) { $sources.Add($PathToAdd) }
        }
    }

    function Match-PoolsByStem {
        param(
            [object[]]$Pools,
            [string]$Kind
        )
        # 1. Exact stem match (例: Foo.lib -> Foo.h / Foo.cpp)
        foreach ($pool in $Pools) {
            foreach ($fPath in $pool) {
                if ([string]::IsNullOrWhiteSpace($fPath)) { continue }
                $fStem = [System.IO.Path]::GetFileNameWithoutExtension($fPath)
                if ($fStem -ieq $baseName) {
                    Add-MatchedFile -PathToAdd $fPath -Kind $Kind
                }
            }
        }
        # 2. Normalized stem match (例: Foo.lib -> Foo_version.h / FooVersion.cpp)
        foreach ($pool in $Pools) {
            foreach ($fPath in $pool) {
                if ([string]::IsNullOrWhiteSpace($fPath)) { continue }
                $fStem = [System.IO.Path]::GetFileNameWithoutExtension($fPath)
                $fNorm = [regex]::Replace($fStem, '(?:(?i)[_-](?:version|ver)$|(?-i:Version)$)', '')
                if ($fStem -ieq $normName -or (-not [string]::IsNullOrWhiteSpace($fNorm) -and $fNorm -ieq $normName)) {
                    Add-MatchedFile -PathToAdd $fPath -Kind $Kind
                }
            }
        }
    }

    # ライブラリ自身をビルドする .vcxproj がある場合はその ClInclude / ClCompile を優先プールに含める
    $projHeaders = @()
    $projSources = @()
    foreach ($stemKey in @($baseName, $normName)) {
        if (-not [string]::IsNullOrWhiteSpace($stemKey) -and $ProjectCodeFilesByStem.ContainsKey($stemKey)) {
            $projEntry = $ProjectCodeFilesByStem[$stemKey]
            $projHeaders += @($projEntry.Headers)
            $projSources += @($projEntry.Sources)
        }
    }

    Match-PoolsByStem -Pools @($projHeaders, $TlogHeaders, $IncludeDirHeaders, $AllProductHeaders) -Kind 'Header'
    Match-PoolsByStem -Pools @($projSources, $AllProductSources) -Kind 'Source'

    # 3. ライブラリ固有プロジェクト配下の残りの ClInclude / ClCompile を追加
    foreach ($ph in $projHeaders) { Add-MatchedFile -PathToAdd $ph -Kind 'Header' }
    foreach ($ps in $projSources) { Add-MatchedFile -PathToAdd $ps -Kind 'Source' }

    # 4. 同一パッケージディレクトリ配下の include/ と src/ マッチ
    if (-not [string]::IsNullOrWhiteSpace($DepFullPath) -and (Test-Path -LiteralPath $DepFullPath)) {
        $libDir      = Split-Path -Path $DepFullPath -Parent
        $pkgDir      = Split-Path -Path $libDir -Parent
        $productFull = [System.IO.Path]::GetFullPath($ProductDir).TrimEnd('\', '/')

        if (-not [string]::IsNullOrWhiteSpace($pkgDir)) {
            $siblingInc = Join-Path $pkgDir 'include'
            if (Test-Path -LiteralPath $siblingInc) {
                $incCands = @(Get-ChildItem -LiteralPath $siblingInc -File -Recurse | Where-Object {
                    (-not (Test-IsExcludedPath -FullPath $_.FullName -BaseDir $ProductDir)) -and
                    ($_.Extension -imatch '^\.h(?:pp|xx)?$')
                })
                if ($incCands.Count -eq 1) {
                    Add-MatchedFile -PathToAdd $incCands[0].FullName -Kind 'Header'
                }
                elseif ($incCands.Count -gt 1) {
                    foreach ($c in ($incCands | Where-Object { $_.BaseName -imatch '(?:^|[_-])(?:version|ver)$|(?-i:Version)' } | Sort-Object Name)) {
                        Add-MatchedFile -PathToAdd $c.FullName -Kind 'Header'
                    }
                }
            }

            # サブパッケージ固有ディレクトリ ($pkgDir != $productDir) の場合、同パッケージ内のソースファイルも探索
            $pkgFull = [System.IO.Path]::GetFullPath($pkgDir).TrimEnd('\', '/')
            if ($pkgFull -ine $productFull) {
                $siblingLibs = @(Get-ChildItem -LiteralPath $libDir -Filter '*.lib' -File)
                $isSingleLibPkg = ($siblingLibs.Count -le 1)
                $pkgSearchDirs = @((Join-Path $pkgDir 'src'), (Join-Path $pkgDir 'source'), $pkgDir) | Where-Object { Test-Path -LiteralPath $_ }

                foreach ($sDir in $pkgSearchDirs) {
                    $recurseFlag = ($sDir -ine $pkgDir)
                    $srcCands = @(Get-ChildItem -LiteralPath $sDir -File -Recurse:$recurseFlag | Where-Object {
                        (-not (Test-IsExcludedPath -FullPath $_.FullName -BaseDir $ProductDir)) -and
                        ($_.Extension -imatch '^\.c(?:pp|xx|c)?$')
                    } | Sort-Object FullName)

                    if ($isSingleLibPkg) {
                        foreach ($sc in $srcCands) {
                            Add-MatchedFile -PathToAdd $sc.FullName -Kind 'Source'
                        }
                    }
                    else {
                        Match-PoolsByStem -Pools @(, @($srcCands | ForEach-Object { $_.FullName })) -Kind 'Source'
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        Headers = $headers.ToArray()
        Sources = $sources.ToArray()
    }
}

function Register-DependencyItem {
    param(
        [Parameter(Mandatory = $true)][hashtable]$DepMap,
        [Parameter(Mandatory = $true)][hashtable]$OnDiskPathMap,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$StandardSystemLibs,
        [Parameter(Mandatory = $true)][bool]$IncludeSystemLibs,
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$ResolvedPath,
        [Parameter(Mandatory = $true)][string]$SourceTag,
        [string]$ProjectName
    )
    $ext = [System.IO.Path]::GetExtension($FileName).ToLowerInvariant()
    if ($ext -ne '.lib' -and $ext -ne '.dll') {
        return
    }
    if (-not $IncludeSystemLibs -and $StandardSystemLibs.Contains($FileName)) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedPath) -and $OnDiskPathMap.ContainsKey($ResolvedPath)) {
        $ResolvedPath = $OnDiskPathMap[$ResolvedPath]
        $FileName     = Split-Path -Path $ResolvedPath -Leaf
    }

    $hasResolvedFile = (-not [string]::IsNullOrWhiteSpace($ResolvedPath) -and (Test-Path -LiteralPath $ResolvedPath -PathType Leaf))
    $key = if ($hasResolvedFile) {
        [System.IO.Path]::GetFullPath($ResolvedPath).ToLowerInvariant()
    }
    else {
        "unresolved::$($FileName.ToLowerInvariant())"
    }

    $unresolvedKey = "unresolved::$($FileName.ToLowerInvariant())"

    if (-not $DepMap.ContainsKey($key)) {
        $DepMap[$key] = [PSCustomObject]@{
            FileName = $FileName
            FileType = $ext
            FullPath = if ($hasResolvedFile) { [System.IO.Path]::GetFullPath($ResolvedPath) } else { $null }
            Sources  = New-Object System.Collections.Generic.List[string]
            Projects = New-Object System.Collections.Generic.List[string]
        }
    }

    # 先に未解決キーで登録されていた場合は実ファイル解決エントリへ統合する
    if ($hasResolvedFile -and $DepMap.ContainsKey($unresolvedKey)) {
        $oldEntry = $DepMap[$unresolvedKey]
        foreach ($s in $oldEntry.Sources) {
            if (-not $DepMap[$key].Sources.Contains($s)) { $DepMap[$key].Sources.Add($s) }
        }
        foreach ($p in $oldEntry.Projects) {
            if (-not $DepMap[$key].Projects.Contains($p)) { $DepMap[$key].Projects.Add($p) }
        }
        $DepMap.Remove($unresolvedKey)
    }

    if (-not $DepMap[$key].Sources.Contains($SourceTag)) {
        $DepMap[$key].Sources.Add($SourceTag)
    }
    if (-not [string]::IsNullOrWhiteSpace($ProjectName) -and -not $DepMap[$key].Projects.Contains($ProjectName)) {
        $DepMap[$key].Projects.Add($ProjectName)
    }
}

function Resolve-DependencyFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$FileNameOrPath,
        [Parameter(Mandatory = $true)][string]$BaseDir,
        [Parameter(Mandatory = $true)][string]$ProductDir,
        [AllowEmptyCollection()][string[]]$LibDirs = @(),
        [Parameter(Mandatory = $true)][hashtable]$FilesByName
    )
    $candidate = Expand-MsBuildPath -RawPath $FileNameOrPath -ProjectDir $BaseDir -ProductDir $ProductDir
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($candidate)
    }
    $leafName = Split-Path -Path $FileNameOrPath -Leaf
    foreach ($ld in $LibDirs) {
        $inLibDir = Join-Path $ld $leafName
        if (Test-Path -LiteralPath $inLibDir -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($inLibDir)
        }
    }
    if ($FilesByName.ContainsKey($leafName)) {
        return $FilesByName[$leafName][0].FullName
    }
    return $null
}

# ==============================================================================
# メイン処理: 製品フォルダ一覧の特定
# ==============================================================================
if (-not (Test-Path -LiteralPath $RootPath)) {
    throw "指定された RootPath が存在しません: $RootPath"
}
$rootFull = [System.IO.Path]::GetFullPath($RootPath)

# RootPath 直下に .vcxproj / .csproj がある場合は単一製品フォルダとして扱い、そうでなければ直下のサブフォルダを製品フォルダとして扱う
$directProjects = @(Get-ChildItem -LiteralPath $rootFull -Filter '*.vcxproj' -File) +
                  @(Get-ChildItem -LiteralPath $rootFull -Filter '*.csproj' -File)
if ($directProjects.Count -gt 0) {
    $productDirs = @(Get-Item -LiteralPath $rootFull)
}
else {
    $productDirs = @(Get-ChildItem -LiteralPath $rootFull -Directory | Sort-Object Name)
}

$inventoryResults = New-Object System.Collections.Generic.List[PSCustomObject]

foreach ($prodDirItem in $productDirs) {
    $productName = $prodDirItem.Name
    $productDir  = $prodDirItem.FullName

    # 製品内の全ファイルを1回だけ走査してインデックス化 (obj/.vs/.git/TestResults/ipch は除外)
    $onDiskPathLookup  = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    $filesByNameLookup = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    $productFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($fsItem in (Get-ChildItem -LiteralPath $productDir -File -Recurse)) {
        if (Test-IsExcludedPath -FullPath $fsItem.FullName -BaseDir $productDir) {
            continue
        }
        $productFiles.Add($fsItem)
        $onDiskPathLookup[$fsItem.FullName] = $fsItem.FullName

        if (-not $filesByNameLookup.ContainsKey($fsItem.Name)) {
            $filesByNameLookup[$fsItem.Name] = New-Object System.Collections.Generic.List[System.IO.FileInfo]
        }
        $filesByNameLookup[$fsItem.Name].Add($fsItem)
    }

    $depMap      = @{}
    $includeDirs = New-Object System.Collections.Generic.List[string]
    $libDirs     = New-Object System.Collections.Generic.List[string]
    $tlogHeaders = New-Object System.Collections.Generic.List[string]

    # --------------------------------------------------------------------------
    # 1. .vcxproj / .csproj の解析
    # --------------------------------------------------------------------------
    $vcxprojFiles = @($productFiles | Where-Object { $_.Extension -ieq '.vcxproj' })
    $csprojFiles  = @($productFiles | Where-Object { $_.Extension -ieq '.csproj' })

    # プロジェクト名 (拡張子なし) -> プロジェクトファイル名 マップ (tlogからの逆引き用)
    $projNameMap = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($pf in ($vcxprojFiles + $csprojFiles)) {
        $projNameMap[$pf.BaseName] = $pf.Name
    }

    # StaticLibrary / DynamicLibrary プロジェクトが所有する ClInclude / ClCompile を収集
    $projectCodeFilesByStem = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($vcx in $vcxprojFiles) {
        $projDir = $vcx.DirectoryName
        [xml]$xmlDoc = Read-TextAutoEncoding -FilePath $vcx.FullName

        $cfgTypeNode = $xmlDoc.SelectSingleNode("//*[local-name()='ConfigurationType']")
        $cfgType = if ($null -ne $cfgTypeNode) { $cfgTypeNode.InnerText.Trim() } else { '' }
        if ($cfgType -ieq 'StaticLibrary' -or $cfgType -ieq 'DynamicLibrary') {
            $projHeadersList = New-Object System.Collections.Generic.List[string]
            $projSourcesList = New-Object System.Collections.Generic.List[string]

            foreach ($incNode in $xmlDoc.SelectNodes("//*[local-name()='ClInclude']")) {
                $incVal = $incNode.GetAttribute('Include')
                if ([string]::IsNullOrWhiteSpace($incVal)) { continue }
                $resolvedH = Expand-MsBuildPath -RawPath $incVal -ProjectDir $projDir -ProductDir $productDir
                if ((Test-Path -LiteralPath $resolvedH -PathType Leaf) -and -not $projHeadersList.Contains($resolvedH)) {
                    $projHeadersList.Add($resolvedH)
                }
            }
            foreach ($srcNode in $xmlDoc.SelectNodes("//*[local-name()='ClCompile']")) {
                $srcVal = $srcNode.GetAttribute('Include')
                if ([string]::IsNullOrWhiteSpace($srcVal)) { continue }
                $resolvedS = Expand-MsBuildPath -RawPath $srcVal -ProjectDir $projDir -ProductDir $productDir
                if ((Test-Path -LiteralPath $resolvedS -PathType Leaf) -and -not $projSourcesList.Contains($resolvedS)) {
                    $projSourcesList.Add($resolvedS)
                }
            }

            $targetNameNode = $xmlDoc.SelectSingleNode("//*[local-name()='TargetName']")
            $projNameNode   = $xmlDoc.SelectSingleNode("//*[local-name()='ProjectName']")
            $stems = @($vcx.BaseName)
            if ($null -ne $targetNameNode -and -not [string]::IsNullOrWhiteSpace($targetNameNode.InnerText)) {
                $stems += $targetNameNode.InnerText.Trim()
            }
            if ($null -ne $projNameNode -and -not [string]::IsNullOrWhiteSpace($projNameNode.InnerText)) {
                $stems += $projNameNode.InnerText.Trim()
            }
            foreach ($st in ($stems | Select-Object -Unique)) {
                $projectCodeFilesByStem[$st] = [PSCustomObject]@{
                    Headers = $projHeadersList.ToArray()
                    Sources = $projSourcesList.ToArray()
                }
            }
        }

        # AdditionalIncludeDirectories
        $incNodes = $xmlDoc.SelectNodes("//*[local-name()='AdditionalIncludeDirectories']")
        foreach ($node in $incNodes) {
            foreach ($part in ($node.InnerText -split ';')) {
                $trimmed = $part.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -like '%(*)*') { continue }
                $resolvedInc = Expand-MsBuildPath -RawPath $trimmed -ProjectDir $projDir -ProductDir $productDir
                if ((Test-Path -LiteralPath $resolvedInc) -and -not $includeDirs.Contains($resolvedInc)) {
                    $includeDirs.Add($resolvedInc)
                }
            }
        }

        # AdditionalLibraryDirectories
        $libDirNodes = $xmlDoc.SelectNodes("//*[local-name()='AdditionalLibraryDirectories']")
        foreach ($node in $libDirNodes) {
            foreach ($part in ($node.InnerText -split ';')) {
                $trimmed = $part.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -like '%(*)*') { continue }
                $resolvedLibDir = Expand-MsBuildPath -RawPath $trimmed -ProjectDir $projDir -ProductDir $productDir
                if ((Test-Path -LiteralPath $resolvedLibDir) -and -not $libDirs.Contains($resolvedLibDir)) {
                    $libDirs.Add($resolvedLibDir)
                }
            }
        }
    }

    $libDirsArr = $libDirs.ToArray()

    # .vcxproj / .csproj 共通の ProjectReference・Reference 解析処理
    function Process-ProjectReferencesAndHints {
        param(
            [xml]$XmlDoc,
            [string]$ProjDir,
            [string]$ProjName,
            [string]$ProjKind
        )
        # ProjectReference
        $projRefNodes = $XmlDoc.SelectNodes("//*[local-name()='ProjectReference']")
        foreach ($node in $projRefNodes) {
            $incAttr = $node.GetAttribute('Include')
            if ([string]::IsNullOrWhiteSpace($incAttr)) { continue }
            $refProjPath = Expand-MsBuildPath -RawPath $incAttr -ProjectDir $ProjDir -ProductDir $productDir
            $refProjDir  = Split-Path -Path $refProjPath -Parent
            $refStem     = [System.IO.Path]::GetFileNameWithoutExtension($refProjPath)

            if (Test-Path -LiteralPath $refProjDir) {
                $refOutputs = @(Get-ChildItem -LiteralPath $refProjDir -File -Recurse | Where-Object {
                    (-not (Test-IsExcludedPath -FullPath $_.FullName -BaseDir $productDir)) -and
                    ($_.Extension -ieq '.lib' -or $_.Extension -ieq '.dll') -and
                    ($_.BaseName -ieq $refStem)
                })
                foreach ($outFile in $refOutputs) {
                    Register-DependencyItem -DepMap $depMap -OnDiskPathMap $onDiskPathLookup -StandardSystemLibs $StandardSystemLibs -IncludeSystemLibs ([bool]$IncludeSystemLibs) `
                        -FileName $outFile.Name -ResolvedPath $outFile.FullName -SourceTag "${ProjKind}(ProjectReference)" -ProjectName $ProjName
                }
            }
        }

        # Reference (HintPath付きDLL参照)
        $refNodes = $XmlDoc.SelectNodes("//*[local-name()='Reference']")
        foreach ($node in $refNodes) {
            $hintNode = $node.SelectSingleNode("*[local-name()='HintPath']")
            if ($null -ne $hintNode -and -not [string]::IsNullOrWhiteSpace($hintNode.InnerText)) {
                $hintPath = $hintNode.InnerText.Trim()
                $leaf     = Split-Path -Path $hintPath -Leaf
                $resolved = Resolve-DependencyFilePath -FileNameOrPath $hintPath -BaseDir $ProjDir -ProductDir $productDir -LibDirs $libDirsArr -FilesByName $filesByNameLookup
                Register-DependencyItem -DepMap $depMap -OnDiskPathMap $onDiskPathLookup -StandardSystemLibs $StandardSystemLibs -IncludeSystemLibs ([bool]$IncludeSystemLibs) `
                    -FileName $leaf -ResolvedPath $resolved -SourceTag "${ProjKind}(Reference)" -ProjectName $ProjName
            }
        }
    }

    foreach ($vcx in $vcxprojFiles) {
        $projDir  = $vcx.DirectoryName
        $projName = $vcx.Name
        [xml]$xmlDoc = Read-TextAutoEncoding -FilePath $vcx.FullName

        # AdditionalDependencies
        $depNodes = $xmlDoc.SelectNodes("//*[local-name()='AdditionalDependencies']")
        foreach ($node in $depNodes) {
            foreach ($part in ($node.InnerText -split ';')) {
                $trimmed = $part.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -like '%(*)*') { continue }
                $leaf = Split-Path -Path $trimmed -Leaf
                if (-not $IncludeSystemLibs -and $StandardSystemLibs.Contains($leaf)) { continue }
                $resolved = Resolve-DependencyFilePath -FileNameOrPath $trimmed -BaseDir $projDir -ProductDir $productDir -LibDirs $libDirsArr -FilesByName $filesByNameLookup
                Register-DependencyItem -DepMap $depMap -OnDiskPathMap $onDiskPathLookup -StandardSystemLibs $StandardSystemLibs -IncludeSystemLibs ([bool]$IncludeSystemLibs) `
                    -FileName $leaf -ResolvedPath $resolved -SourceTag 'vcxproj(AdditionalDependencies)' -ProjectName $projName
            }
        }

        Process-ProjectReferencesAndHints -XmlDoc $xmlDoc -ProjDir $projDir -ProjName $projName -ProjKind 'vcxproj'
    }

    foreach ($cs in $csprojFiles) {
        $projDir  = $cs.DirectoryName
        $projName = $cs.Name
        [xml]$xmlDoc = Read-TextAutoEncoding -FilePath $cs.FullName
        Process-ProjectReferencesAndHints -XmlDoc $xmlDoc -ProjDir $projDir -ProjName $projName -ProjKind 'csproj'
    }

    # --------------------------------------------------------------------------
    # 2. CL.read.*.tlog と link.read.*.tlog の解析
    # --------------------------------------------------------------------------
    $clTlogs   = @($productFiles | Where-Object { $_.Name -like 'CL.read.*.tlog' })
    $linkTlogs = @($productFiles | Where-Object { $_.Name -like 'link.read.*.tlog' })

    foreach ($tlog in $clTlogs) {
        $content = Read-TextAutoEncoding -FilePath $tlog.FullName
        foreach ($rawLine in ($content -split '\r?\n')) {
            $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('^') -or $line.StartsWith('#')) { continue }
            $ext = [System.IO.Path]::GetExtension($line)
            if ($ext -ieq '.h' -or $ext -ieq '.hpp' -or $ext -ieq '.hxx') {
                if ($onDiskPathLookup.ContainsKey($line)) {
                    $exactHeader = $onDiskPathLookup[$line]
                    if (-not $tlogHeaders.Contains($exactHeader)) {
                        $tlogHeaders.Add($exactHeader)
                    }
                }
                elseif (Test-Path -LiteralPath $line -PathType Leaf) {
                    $exactHeader = (Get-Item -LiteralPath $line).FullName
                    if (-not $tlogHeaders.Contains($exactHeader)) {
                        $tlogHeaders.Add($exactHeader)
                    }
                }
                else {
                    # ビルド環境パスが異なる場合、製品内の同名ヘッダをインデックスから検索
                    $hLeaf = Split-Path -Path $line -Leaf
                    if ($filesByNameLookup.ContainsKey($hLeaf)) {
                        $candPath = $filesByNameLookup[$hLeaf][0].FullName
                        if (-not $tlogHeaders.Contains($candPath)) {
                            $tlogHeaders.Add($candPath)
                        }
                    }
                }
            }
        }
    }

    foreach ($tlog in $linkTlogs) {
        # .tlog の親フォルダ名 (例: ProductA.tlog) から参照元プロジェクト名を特定
        $tlogProjName = ''
        $tlogParentLeaf = Split-Path -Path $tlog.DirectoryName -Leaf
        if ($tlogParentLeaf -match '^(?<pname>.+)\.tlog$') {
            $pStem = $Matches['pname']
            if ($projNameMap.ContainsKey($pStem)) {
                $tlogProjName = $projNameMap[$pStem]
            }
        }

        $content = Read-TextAutoEncoding -FilePath $tlog.FullName
        foreach ($rawLine in ($content -split '\r?\n')) {
            $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('^') -or $line.StartsWith('#')) { continue }
            $ext = [System.IO.Path]::GetExtension($line).ToLowerInvariant()
            if ($ext -eq '.lib' -or $ext -eq '.dll') {
                $leaf = Split-Path -Path $line -Leaf
                if (-not $IncludeSystemLibs -and $StandardSystemLibs.Contains($leaf)) { continue }
                if (-not $IncludeSystemLibs -and $line -imatch '\\WINDOWS KITS\\|\\MICROSOFT VISUAL STUDIO\\') { continue }

                $resolved = $null
                if ($onDiskPathLookup.ContainsKey($line)) {
                    $resolved = $onDiskPathLookup[$line]
                }
                elseif (Test-Path -LiteralPath $line -PathType Leaf) {
                    $resolved = (Get-Item -LiteralPath $line).FullName
                }
                else {
                    $resolved = Resolve-DependencyFilePath -FileNameOrPath $leaf -BaseDir $productDir -ProductDir $productDir -LibDirs $libDirsArr -FilesByName $filesByNameLookup
                }
                $canonicalName = if ($null -ne $resolved) { Split-Path -Path $resolved -Leaf } else { $leaf }
                Register-DependencyItem -DepMap $depMap -OnDiskPathMap $onDiskPathLookup -StandardSystemLibs $StandardSystemLibs -IncludeSystemLibs ([bool]$IncludeSystemLibs) `
                    -FileName $canonicalName -ResolvedPath $resolved -SourceTag 'tlog(link.read)' -ProjectName $tlogProjName
            }
        }
    }

    # --------------------------------------------------------------------------
    # 3. ファイルシステム上の .lib / .dll スキャン (中間フォルダ除外済みインデックスを使用)
    # --------------------------------------------------------------------------
    $fsFiles = @($productFiles | Where-Object { $_.Extension -ieq '.lib' -or $_.Extension -ieq '.dll' })
    foreach ($f in $fsFiles) {
        Register-DependencyItem -DepMap $depMap -OnDiskPathMap $onDiskPathLookup -StandardSystemLibs $StandardSystemLibs -IncludeSystemLibs ([bool]$IncludeSystemLibs) `
            -FileName $f.Name -ResolvedPath $f.FullName -SourceTag 'FileSystem' -ProjectName ''
    }

    # --------------------------------------------------------------------------
    # 4. ヘッダ／ソースファイル候補プールの構築
    # --------------------------------------------------------------------------
    $includeDirHeaders = New-Object System.Collections.Generic.List[string]
    foreach ($incDir in $includeDirs) {
        if (Test-Path -LiteralPath $incDir) {
            foreach ($h in (Get-ChildItem -LiteralPath $incDir -File -Recurse | Where-Object { $_.Extension -imatch '^\.h(?:pp|xx)?$' })) {
                if (-not (Test-IsExcludedPath -FullPath $h.FullName -BaseDir $productDir) -and -not $includeDirHeaders.Contains($h.FullName)) {
                    $includeDirHeaders.Add($h.FullName)
                }
            }
        }
    }
    $allProductHeaders = @($productFiles |
        Where-Object { $_.Extension -imatch '^\.h(?:pp|xx)?$' } |
        ForEach-Object { $_.FullName })
    $allProductSources = @($productFiles |
        Where-Object { $_.Extension -imatch '^\.c(?:pp|xx|c)?$' } |
        ForEach-Object { $_.FullName })

    # --------------------------------------------------------------------------
    # 5. 各依存ライブラリのバージョン抽出（優先順位厳守）
    #    バイナリ情報(.dll) ＞ フォルダ名 ＞ #define ＞ 改訂履歴コメント ＞ 更新日時
    # --------------------------------------------------------------------------
    $sortedDeps = $depMap.Values | Sort-Object FileType, FileName
    foreach ($dep in $sortedDeps) {
        $assocFiles = Find-AssociatedCodeFiles `
            -DepFileName $dep.FileName `
            -DepFullPath $dep.FullPath `
            -ProductDir $productDir `
            -TlogHeaders $tlogHeaders.ToArray() `
            -IncludeDirHeaders $includeDirHeaders.ToArray() `
            -AllProductHeaders $allProductHeaders `
            -AllProductSources $allProductSources `
            -ProjectCodeFilesByStem $projectCodeFilesByStem

        $candidateHeaders   = @($assocFiles.Headers)
        $candidateSources   = @($assocFiles.Sources)
        $candidateCodeFiles = @($candidateHeaders + $candidateSources)

        $primaryHeader = if ($candidateHeaders.Count -gt 0) { $candidateHeaders[0] } else { '' }
        $primarySource = if ($candidateSources.Count -gt 0) { $candidateSources[0] } else { '' }
        $verResult     = $null

        # [優先順位 1] バイナリ情報 (.dll)
        if ($dep.FileType -ieq '.dll' -and -not [string]::IsNullOrWhiteSpace($dep.FullPath)) {
            $verResult = Get-BinaryDllVersion -DllPath $dep.FullPath
        }

        # [優先順位 2] フォルダ名
        if ($null -eq $verResult) {
            $pathsToCheck = New-Object System.Collections.Generic.List[string]
            if (-not [string]::IsNullOrWhiteSpace($dep.FullPath)) { $pathsToCheck.Add($dep.FullPath) }
            foreach ($cf in $candidateCodeFiles) { $pathsToCheck.Add($cf) }
            if ($pathsToCheck.Count -gt 0) {
                $verResult = Get-FolderVersion -TargetPaths $pathsToCheck.ToArray() -ProductDir $productDir -RootDir $rootFull
            }
        }

        # [優先順位 3] #define (ヘッダ・ソース全体から抽出し最新を採用)
        if ($null -eq $verResult -and $candidateCodeFiles.Count -gt 0) {
            $defineCandidates = New-Object System.Collections.Generic.List[object]
            foreach ($cf in $candidateCodeFiles) {
                $defVer = Get-CodeDefineVersion -FilePath $cf
                if ($null -ne $defVer) {
                    $defineCandidates.Add($defVer)
                }
            }
            if ($defineCandidates.Count -gt 0) {
                $verResult = Select-LatestVersionResult -Candidates $defineCandidates.ToArray()
            }
        }

        # [優先順位 4] 改訂履歴コメント (ヘッダ・ソース全体を検索し最新バージョンを採用)
        if ($null -eq $verResult -and $candidateCodeFiles.Count -gt 0) {
            $historyCandidates = New-Object System.Collections.Generic.List[object]
            foreach ($cf in $candidateCodeFiles) {
                $histVer = Get-CodeHistoryVersion -FilePath $cf
                if ($null -ne $histVer) {
                    $historyCandidates.Add($histVer)
                }
            }
            if ($historyCandidates.Count -gt 0) {
                $verResult = Select-LatestVersionResult -Candidates $historyCandidates.ToArray()
            }
        }

        # [優先順位 5] 更新日時 (タイムスタンプフォールバック)
        $lastWriteStr = ''
        if (-not [string]::IsNullOrWhiteSpace($dep.FullPath) -and (Test-Path -LiteralPath $dep.FullPath)) {
            $lastWriteStr = (Get-Item -LiteralPath $dep.FullPath).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        }
        if ($null -eq $verResult) {
            if (-not [string]::IsNullOrWhiteSpace($lastWriteStr)) {
                $verResult = [PSCustomObject]@{
                    Version       = $lastWriteStr
                    VersionSource = '更新日時'
                    Status        = 'OK'
                    SourceFile    = $primaryHeader
                    Notes         = 'バージョン記載なしのためファイル更新日時へフォールバック'
                }
            }
            else {
                $verResult = [PSCustomObject]@{
                    Version       = '不明(ファイル未検出)'
                    VersionSource = '未検出'
                    Status        = '要目視確認'
                    SourceFile    = $primaryHeader
                    Notes         = '実ファイルおよびヘッダが見つかりません'
                }
            }
        }

        $usedFilePath = if ($verResult.PSObject.Properties['SourceFile'] -and -not [string]::IsNullOrWhiteSpace($verResult.SourceFile)) {
            $verResult.SourceFile
        } else {
            ''
        }
        $usedHeaderPath = if (-not [string]::IsNullOrWhiteSpace($usedFilePath) -and $usedFilePath -imatch '\.h(?:pp|xx)?$') {
            $usedFilePath
        } else {
            $primaryHeader
        }
        $usedSourcePath = if (-not [string]::IsNullOrWhiteSpace($usedFilePath) -and $usedFilePath -imatch '\.c(?:pp|xx|c)?$') {
            $usedFilePath
        } else {
            $primarySource
        }

        $relFilePath = if (-not [string]::IsNullOrWhiteSpace($dep.FullPath)) {
            Get-NormalizedRelativePath -BasePath $rootFull -TargetPath $dep.FullPath
        } else { '(未解決)' }

        $relHeaderPath = if (-not [string]::IsNullOrWhiteSpace($usedHeaderPath)) {
            Get-NormalizedRelativePath -BasePath $rootFull -TargetPath $usedHeaderPath
        } else { '' }

        $relSourcePath = if (-not [string]::IsNullOrWhiteSpace($usedSourcePath)) {
            Get-NormalizedRelativePath -BasePath $rootFull -TargetPath $usedSourcePath
        } else { '' }

        $projDisplay = if ($dep.Projects.Count -gt 0) {
            ($dep.Projects -join '; ')
        } else {
            '(フォルダ検出)'
        }

        $inventoryResults.Add([PSCustomObject]@{
            Product         = $productName
            Project         = $projDisplay
            FileName        = $dep.FileName
            FileType        = $dep.FileType
            Version         = $verResult.Version
            VersionSource   = $verResult.VersionSource
            Status          = $verResult.Status
            DetectedSources = ($dep.Sources -join '; ')
            HeaderFile      = $relHeaderPath
            SourceFile      = $relSourcePath
            FilePath        = $relFilePath
            LastWriteTime   = $lastWriteStr
            Notes           = $verResult.Notes
        })
    }
}

# ==============================================================================
# UTF-8 (BOM付き) CSV 出力（Excelで文字化けしない形式）
# ==============================================================================
$outputDir = Split-Path -Path ([System.IO.Path]::GetFullPath($OutputCsvPath)) -Parent
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$csvLines = $inventoryResults | ConvertTo-Csv -NoTypeInformation
$csvText  = ($csvLines -join "`r`n") + "`r`n"
$utf8Bom  = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutputCsvPath), $csvText, $utf8Bom)

Write-Host "インベントリCSVを出力しました (UTF-8 BOM付き, 全$($inventoryResults.Count)件): $OutputCsvPath" -ForegroundColor Green

if ($PassThru) {
    return $inventoryResults
}
