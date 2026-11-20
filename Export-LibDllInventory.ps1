<#
.SYNOPSIS
    Windowsアプリ（C++ / .NET混在想定）の製品フォルダ配下から、依存している .lib / .dll と各バージョンを
    ルールベース（正規表現＋メタデータ）で機械的に抽出し、UTF-8 (BOM付き) CSV に出力します。

.DESCRIPTION
    【バージョン抽出の優先順位】
      1. バイナリ情報 (.dll の FileVersion / ProductVersion)
      2. フォルダ名 (例: ThirdParty_v2.4.1)
      3. #define (対応する .h ファイル内の有効なマクロ定義。コメントアウトや #if 0 は除外)
      4. 改訂履歴コメント (.h ファイル内の履歴コメント。昇順・降順を自動判定)
         ※昇順・降順が判別できない場合は「先頭: X.X.X / 末尾: Y.Y.Y」を出力し、Status列を「要目視確認」に設定
      5. 更新日時 (対象ファイルの LastWriteTime にフォールバック)

    【依存関係の検出元】
      - .vcxproj (AdditionalDependencies, ProjectReference, Reference, AdditionalIncludeDirectories, AdditionalLibraryDirectories)
      - .csproj (Reference, ProjectReference)
      - link.read.*.tlog / CL.read.*.tlog
      - 製品フォルダ配下のファイルシステム探索 (.lib / .dll)

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

function ConvertTo-VersionTuple {
    param([Parameter(Mandatory = $true)][string]$VersionString)
    # 数値パート (Major.Minor.Patch.Build) を4要素の整数配列に変換
    $clean = $VersionString -replace '^[^\d]+', ''
    $numPart = ($clean -split '[^0-9\.]')[0]
    $parts = $numPart -split '\.'
    $tuple = @(0, 0, 0, 0)
    for ($i = 0; $i -lt [Math]::Min($parts.Count, 4); $i++) {
        $val = 0
        if ([int]::TryParse($parts[$i], [ref]$val)) {
            $tuple[$i] = $val
        }
    }
    return ,$tuple
}

function Compare-VersionTuple {
    param(
        [int[]]$TupleA,
        [int[]]$TupleB
    )
    for ($i = 0; $i -lt 4; $i++) {
        if ($TupleA[$i] -lt $TupleB[$i]) { return -1 }
        if ($TupleA[$i] -gt $TupleB[$i]) { return 1 }
    }
    return 0
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
                # 0.0.0.0 のような空バージョンは未設定とみなす
                if ($trimmed -match '(?<ver>\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z\.]+)?)' -and $Matches['ver'] -notmatch '^0\.0(?:\.0){0,2}$') {
                    return [PSCustomObject]@{
                        Version       = $Matches['ver']
                        VersionSource = 'バイナリ情報(.dll)'
                        Status        = 'OK'
                        Notes         = "DLLメタデータ (FileVersion: $($vi.FileVersion), ProductVersion: $($vi.ProductVersion))"
                    }
                }
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
        [Parameter(Mandatory = $true)][string[]]$TargetPaths,
        [Parameter(Mandatory = $true)][string]$ProductDir
    )
    $productFull = [System.IO.Path]::GetFullPath($ProductDir).TrimEnd('\', '/')
    # TargetFramework名などはフォルダバージョン表記から除外
    $ignoreDirRegex = '^(?i)(?:x64|x86|win32|win64|arm64|debug|release|bin|lib|include|src|obj|net\d+(?:\.\d+)?|netstandard\d+\.\d+|netcoreapp\d+\.\d+|.*\.tlog)$'

    foreach ($tPath in $TargetPaths) {
        if ([string]::IsNullOrWhiteSpace($tPath)) { continue }
        $currentDir = Split-Path -Path ([System.IO.Path]::GetFullPath($tPath)) -Parent

        while (-not [string]::IsNullOrWhiteSpace($currentDir) -and
               $currentDir.Length -gt $productFull.Length -and
               $currentDir.StartsWith($productFull, [System.StringComparison]::OrdinalIgnoreCase)) {

            $dirName = Split-Path -Path $currentDir -Leaf
            if ($dirName -notmatch $ignoreDirRegex) {
                # パターン1: ドット区切りバージョン (例: ThirdParty_v2.4.1, Sdk-1.2.3-rc1, Ver2.0.5)
                if ($dirName -match '(?i)(?:^|[_\-\.\s]|ver|version|v)(?<ver>\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z\.]+)?)(?:$|[_\-\s])') {
                    return [PSCustomObject]@{
                        Version       = $Matches['ver']
                        VersionSource = 'フォルダ名'
                        Status        = 'OK'
                        Notes         = "フォルダ名 '$dirName' から抽出"
                    }
                }
                # パターン2: アンダースコア区切りバージョン (例: boost_1_82_0, Lib_v2_4_1)
                if ($dirName -match '(?i)(?:^|[_\-\s])v?(?<ver>\d+_\d+_\d+(?:_\d+)?)(?:$|[_\-\s])') {
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

function Get-HeaderDefineVersion {
    param([Parameter(Mandatory = $true)][string]$HeaderPath)
    if (-not (Test-Path -LiteralPath $HeaderPath)) {
        return $null
    }
    $rawContent = Read-TextAutoEncoding -FilePath $HeaderPath
    $headerLeaf = Split-Path -Path $HeaderPath -Leaf

    # 1. ブロックコメント /* ... */ を除去
    $cleaned = [regex]::Replace($rawContent, '(?s)/\*.*?\*/', '')
    # 2. 単一行コメント // ... を除去
    $cleaned = [regex]::Replace($cleaned, '(?m)//.*$', '')
    # 3. #if 0 ... #endif 無効化ブロックを除去
    $cleaned = [regex]::Replace($cleaned, '(?ms)^\s*#\s*if\s+0\b.*?^\s*#\s*endif\b', '')

    # パターンA: 単一マクロによるバージョン文字列/数値定義 (例: #define ALPHA_VERSION "1.4.2")
    $singleRegex = '(?im)^\s*#\s*define\s+(?<macro>[A-Za-z_][A-Za-z0-9_]*(?:VER|VERSION|RELEASE)[A-Za-z0-9_]*)\s+["'']?v?(?<ver>\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z\._]+)?)["'']?(?:\s|$)'
    $mSingle = [regex]::Match($cleaned, $singleRegex)
    if ($mSingle.Success) {
        return [PSCustomObject]@{
            Version       = $mSingle.Groups['ver'].Value
            VersionSource = '#define'
            Status        = 'OK'
            Notes         = "#define $($mSingle.Groups['macro'].Value) ($headerLeaf)"
        }
    }

    # パターンB: MAJOR / MINOR / (PATCH|BUILD|REVISION) 分割マクロ定義
    $mMajor = [regex]::Match($cleaned, '(?im)^\s*#\s*define\s+(?<macro>[A-Za-z_][A-Za-z0-9_]*_MAJOR)\s+\(?(?<val>\d+)\)?\b')
    $mMinor = [regex]::Match($cleaned, '(?im)^\s*#\s*define\s+(?<macro>[A-Za-z_][A-Za-z0-9_]*_MINOR)\s+\(?(?<val>\d+)\)?\b')
    if ($mMajor.Success -and $mMinor.Success) {
        $verStr = "$($mMajor.Groups['val'].Value).$($mMinor.Groups['val'].Value)"
        $mPatch = [regex]::Match($cleaned, '(?im)^\s*#\s*define\s+(?<macro>[A-Za-z_][A-Za-z0-9_]*_(?:PATCH|BUILD|REVISION|MICRO))\s+\(?(?<val>\d+)\)?\b')
        if ($mPatch.Success) {
            $verStr += ".$($mPatch.Groups['val'].Value)"
        }
        return [PSCustomObject]@{
            Version       = $verStr
            VersionSource = '#define'
            Status        = 'OK'
            Notes         = "#define $($mMajor.Groups['macro'].Value) 他 ($headerLeaf)"
        }
    }

    return $null
}

function Get-HeaderHistoryVersion {
    param([Parameter(Mandatory = $true)][string]$HeaderPath)
    if (-not (Test-Path -LiteralPath $HeaderPath)) {
        return $null
    }
    $rawContent = Read-TextAutoEncoding -FilePath $HeaderPath
    $headerLeaf = Split-Path -Path $HeaderPath -Leaf

    # コメント部分のみを先頭から順序を保って抽出
    $commentMatches = [regex]::Matches($rawContent, '(?s)/\*.*?\*/|(?m)^\s*//.*$')
    if ($commentMatches.Count -eq 0) {
        return $null
    }

    $commentLines = New-Object System.Collections.Generic.List[string]
    foreach ($cm in $commentMatches) {
        foreach ($line in ($cm.Value -split '\r?\n')) {
            $commentLines.Add($line)
        }
    }

    # 改訂履歴のエントリー行を抽出
    $entries = New-Object System.Collections.Generic.List[PSCustomObject]
    $datePattern = '(?<date>(?:19|20)\d{2}[/\-\.](?:0?[1-9]|1[0-2])[/\-\.](?:0?[1-9]|[12]\d|3[01]))'
    $verWithPrefixPattern = '(?:Ver\.?|Version|v|V|Rev\.?|版)\s*:?\s*(?<ver>\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z\.]+)?)\b'
    $verBarePattern = '\b(?<ver>\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z\.]+)?)\b'

    foreach ($line in $commentLines) {
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
        if ($line -match $verWithPrefixPattern) {
            $extractedVer = $Matches['ver']
        }
        elseif ($hasDate) {
            # 日付と同じ行にあるバージョン番号（日付自体を誤抽出しないよう日付部分を除去してから検索）
            $lineWithoutDate = $line -replace $datePattern, ''
            if ($lineWithoutDate -match $verBarePattern) {
                $extractedVer = $Matches['ver']
            }
        }

        if ($null -ne $extractedVer) {
            $entries.Add([PSCustomObject]@{
                RawVersion   = $extractedVer
                VersionTuple = (ConvertTo-VersionTuple -VersionString $extractedVer)
                Date         = $parsedDate
                Line         = $line.Trim()
            })
        }
    }

    if ($entries.Count -eq 0) {
        return $null
    }
    if ($entries.Count -eq 1) {
        return [PSCustomObject]@{
            Version       = $entries[0].RawVersion
            VersionSource = '改訂履歴コメント'
            Status        = 'OK'
            Notes         = "改訂履歴1件のみ ($headerLeaf)"
        }
    }

    # 複数履歴がある場合：昇順（下が最新）か降順（上が最新）かを判定
    $verNonDecreasing = $true
    $verNonIncreasing = $true
    $verHasStrictDiff = $false

    $allHaveDates = @($entries | Where-Object { $null -eq $_.Date }).Count -eq 0
    $dateNonDecreasing = $true
    $dateNonIncreasing = $true
    $dateHasStrictDiff = $false

    for ($i = 0; $i -lt ($entries.Count - 1); $i++) {
        $cmpVer = Compare-VersionTuple -TupleA $entries[$i].VersionTuple -TupleB $entries[$i + 1].VersionTuple
        if ($cmpVer -lt 0) {
            $verNonIncreasing = $false
            $verHasStrictDiff = $true
        }
        elseif ($cmpVer -gt 0) {
            $verNonDecreasing = $false
            $verHasStrictDiff = $true
        }

        if ($allHaveDates) {
            if ($entries[$i].Date -lt $entries[$i + 1].Date) {
                $dateNonIncreasing = $false
                $dateHasStrictDiff = $true
            }
            elseif ($entries[$i].Date -gt $entries[$i + 1].Date) {
                $dateNonDecreasing = $false
                $dateHasStrictDiff = $true
            }
        }
    }

    $verIsAsc  = $verNonDecreasing -and $verHasStrictDiff
    $verIsDesc = $verNonIncreasing -and $verHasStrictDiff
    $verAllEq  = $verNonDecreasing -and $verNonIncreasing

    $dateIsAsc  = $allHaveDates -and $dateNonDecreasing -and $dateHasStrictDiff
    $dateIsDesc = $allHaveDates -and $dateNonIncreasing -and $dateHasStrictDiff
    $dateAllEq  = $allHaveDates -and $dateNonDecreasing -and $dateNonIncreasing

    # 判定ルール:
    # - バージョンが単調増加、かつ日付が無い/単調増加/同一 → 昇順（下が最新）
    # - バージョンが単調減少、かつ日付が無い/単調減少/同一 → 降順（上が最新）
    # - バージョンが全て同一で日付が単調増加 or 単調減少 → 日付の向きに従う
    # - 上記以外（バージョンや日付が非単調、または日付の向きとバージョンの向きが矛盾）→ 判別不能（要目視確認）
    $isAscending = ($verIsAsc -and (-not $allHaveDates -or $dateIsAsc -or $dateAllEq)) -or ($verAllEq -and $dateIsAsc)
    $isDescending = ($verIsDesc -and (-not $allHaveDates -or $dateIsDesc -or $dateAllEq)) -or ($verAllEq -and $dateIsDesc)

    $firstVer = $entries[0].RawVersion
    $lastVer  = $entries[$entries.Count - 1].RawVersion

    if ($isDescending -and -not $isAscending) {
        return [PSCustomObject]@{
            Version       = $firstVer
            VersionSource = '改訂履歴コメント(降順)'
            Status        = 'OK'
            Notes         = "改訂履歴先頭を採用 (全$($entries.Count)件: 先頭=$firstVer, 末尾=$lastVer) [$headerLeaf]"
        }
    }
    elseif ($isAscending -and -not $isDescending) {
        return [PSCustomObject]@{
            Version       = $lastVer
            VersionSource = '改訂履歴コメント(昇順)'
            Status        = 'OK'
            Notes         = "改訂履歴末尾を採用 (全$($entries.Count)件: 先頭=$firstVer, 末尾=$lastVer) [$headerLeaf]"
        }
    }
    else {
        return [PSCustomObject]@{
            Version       = "先頭: $firstVer / 末尾: $lastVer"
            VersionSource = '改訂履歴コメント(順序不明)'
            Status        = '要目視確認'
            Notes         = "履歴の昇順・降順が判別不能なため先頭と末尾を併記 (全$($entries.Count)件) [$headerLeaf]"
        }
    }
}

function Find-AssociatedHeader {
    param(
        [Parameter(Mandatory = $true)][string]$DepFileName,
        [string]$DepFullPath,
        [string[]]$TlogHeaders,
        [string[]]$IncludeDirHeaders,
        [string[]]$AllProductHeaders
    )
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($DepFileName)
    $normName = $baseName -ireplace '^lib(?=[A-Za-z])', ''
    $normName = $normName -ireplace '(?:_d|_debug|_release|_x64|_x86|_static|_dll)$', ''

    $pools = @($TlogHeaders, $IncludeDirHeaders, $AllProductHeaders)

    # 1. Exact stem match
    foreach ($pool in $pools) {
        foreach ($hPath in $pool) {
            if ([string]::IsNullOrWhiteSpace($hPath)) { continue }
            $hStem = [System.IO.Path]::GetFileNameWithoutExtension($hPath)
            if ($hStem -ieq $baseName) {
                return $hPath
            }
        }
    }

    # 2. Normalized stem match
    foreach ($pool in $pools) {
        foreach ($hPath in $pool) {
            if ([string]::IsNullOrWhiteSpace($hPath)) { continue }
            $hStem = [System.IO.Path]::GetFileNameWithoutExtension($hPath)
            $hNorm = $hStem -ireplace '(?:_version|_ver|version|ver)$', ''
            if ($hStem -ieq $normName -or $hNorm -ieq $normName) {
                return $hPath
            }
        }
    }

    # 3. 同一パッケージディレクトリ配下の include/*.h マッチ
    if (-not [string]::IsNullOrWhiteSpace($DepFullPath) -and (Test-Path -LiteralPath $DepFullPath)) {
        $libDir = Split-Path -Path $DepFullPath -Parent
        $pkgDir = Split-Path -Path $libDir -Parent
        if (-not [string]::IsNullOrWhiteSpace($pkgDir)) {
            $siblingInc = Join-Path $pkgDir 'include'
            if (Test-Path -LiteralPath $siblingInc) {
                $candidates = @(Get-ChildItem -LiteralPath $siblingInc -Filter '*.h*' -File -Recurse)
                if ($candidates.Count -eq 1) {
                    return $candidates[0].FullName
                }
            }
        }
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

    # ファイルシステム上の正確な大文字・小文字パスを保持する辞書 (.tlog の大文字パス正規化用)
    $onDiskPathMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($fsItem in (Get-ChildItem -LiteralPath $productDir -File -Recurse)) {
        $onDiskPathMap[$fsItem.FullName] = $fsItem.FullName
    }

    # 製品内の依存アイテムを管理する辞書 (Key: フルパス または 未解決ファイル名小文字)
    $depMap = @{}
    $includeDirs = New-Object System.Collections.Generic.List[string]
    $libDirs     = New-Object System.Collections.Generic.List[string]
    $tlogHeaders = New-Object System.Collections.Generic.List[string]

    function Register-Dependency {
        param(
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

        if (-not [string]::IsNullOrWhiteSpace($ResolvedPath) -and $onDiskPathMap.ContainsKey($ResolvedPath)) {
            $ResolvedPath = $onDiskPathMap[$ResolvedPath]
            $FileName     = Split-Path -Path $ResolvedPath -Leaf
        }

        $key = if (-not [string]::IsNullOrWhiteSpace($ResolvedPath) -and (Test-Path -LiteralPath $ResolvedPath)) {
            [System.IO.Path]::GetFullPath($ResolvedPath).ToLowerInvariant()
        }
        else {
            "unresolved::$($FileName.ToLowerInvariant())"
        }

        if (-not $depMap.ContainsKey($key)) {
            $depMap[$key] = [PSCustomObject]@{
                FileName     = $FileName
                FileType     = $ext
                FullPath     = $ResolvedPath
                Sources      = New-Object System.Collections.Generic.List[string]
                Projects     = New-Object System.Collections.Generic.List[string]
            }
        }
        if (-not $depMap[$key].Sources.Contains($SourceTag)) {
            $depMap[$key].Sources.Add($SourceTag)
        }
        if (-not [string]::IsNullOrWhiteSpace($ProjectName) -and -not $depMap[$key].Projects.Contains($ProjectName)) {
            $depMap[$key].Projects.Add($ProjectName)
        }
    }

    # --------------------------------------------------------------------------
    # 1. .vcxproj / .csproj の解析 ( 먼저 IncludeDir / LibDir を収集 )
    # --------------------------------------------------------------------------
    $vcxprojFiles = @(Get-ChildItem -LiteralPath $productDir -Filter '*.vcxproj' -File -Recurse)
    $csprojFiles  = @(Get-ChildItem -LiteralPath $productDir -Filter '*.csproj' -File -Recurse)

    foreach ($vcx in $vcxprojFiles) {
        $projDir = $vcx.DirectoryName
        [xml]$xmlDoc = Read-TextAutoEncoding -FilePath $vcx.FullName

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

    # ライブラリ名から実ファイルパスを解決するヘルパー
    function Resolve-DepFilePath {
        param(
            [Parameter(Mandatory = $true)][string]$FileNameOrPath,
            [Parameter(Mandatory = $true)][string]$BaseDir
        )
        $candidate = Expand-MsBuildPath -RawPath $FileNameOrPath -ProjectDir $BaseDir -ProductDir $productDir
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
        $leafName = Split-Path -Path $FileNameOrPath -Leaf
        foreach ($ld in $libDirs) {
            $inLibDir = Join-Path $ld $leafName
            if (Test-Path -LiteralPath $inLibDir -PathType Leaf) {
                return [System.IO.Path]::GetFullPath($inLibDir)
            }
        }
        $foundInProd = @(Get-ChildItem -LiteralPath $productDir -Filter $leafName -File -Recurse)
        if ($foundInProd.Count -gt 0) {
            return $foundInProd[0].FullName
        }
        return $null
    }

    # .vcxproj の AdditionalDependencies / ProjectReference / Reference を解析
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
                $resolved = Resolve-DepFilePath -FileNameOrPath $trimmed -BaseDir $projDir
                Register-Dependency -FileName $leaf -ResolvedPath $resolved -SourceTag 'vcxproj(AdditionalDependencies)' -ProjectName $projName
            }
        }

        # ProjectReference
        $projRefNodes = $xmlDoc.SelectNodes("//*[local-name()='ProjectReference']")
        foreach ($node in $projRefNodes) {
            $incAttr = $node.GetAttribute('Include')
            if ([string]::IsNullOrWhiteSpace($incAttr)) { continue }
            $refProjPath = Expand-MsBuildPath -RawPath $incAttr -ProjectDir $projDir -ProductDir $productDir
            $refProjDir  = Split-Path -Path $refProjPath -Parent
            $refStem     = [System.IO.Path]::GetFileNameWithoutExtension($refProjPath)

            if (Test-Path -LiteralPath $refProjDir) {
                $refOutputs = @(Get-ChildItem -LiteralPath $refProjDir -File -Recurse | Where-Object {
                    ($_.Extension -ieq '.lib' -or $_.Extension -ieq '.dll') -and ($_.BaseName -ieq $refStem)
                })
                foreach ($outFile in $refOutputs) {
                    Register-Dependency -FileName $outFile.Name -ResolvedPath $outFile.FullName -SourceTag 'vcxproj(ProjectReference)' -ProjectName $projName
                }
            }
        }

        # Reference (C++/CLI や明示的DLL参照)
        $refNodes = $xmlDoc.SelectNodes("//*[local-name()='Reference']")
        foreach ($node in $refNodes) {
            $hintNode = $node.SelectSingleNode("*[local-name()='HintPath']")
            if ($null -ne $hintNode -and -not [string]::IsNullOrWhiteSpace($hintNode.InnerText)) {
                $hintPath = $hintNode.InnerText.Trim()
                $leaf     = Split-Path -Path $hintPath -Leaf
                $resolved = Resolve-DepFilePath -FileNameOrPath $hintPath -BaseDir $projDir
                Register-Dependency -FileName $leaf -ResolvedPath $resolved -SourceTag 'vcxproj(Reference)' -ProjectName $projName
            }
        }
    }

    # .csproj の Reference / ProjectReference を解析
    foreach ($cs in $csprojFiles) {
        $projDir  = $cs.DirectoryName
        $projName = $cs.Name
        [xml]$xmlDoc = Read-TextAutoEncoding -FilePath $cs.FullName

        $refNodes = $xmlDoc.SelectNodes("//*[local-name()='Reference']")
        foreach ($node in $refNodes) {
            $hintNode = $node.SelectSingleNode("*[local-name()='HintPath']")
            if ($null -ne $hintNode -and -not [string]::IsNullOrWhiteSpace($hintNode.InnerText)) {
                $hintPath = $hintNode.InnerText.Trim()
                $leaf     = Split-Path -Path $hintPath -Leaf
                $resolved = Resolve-DepFilePath -FileNameOrPath $hintPath -BaseDir $projDir
                Register-Dependency -FileName $leaf -ResolvedPath $resolved -SourceTag 'csproj(Reference)' -ProjectName $projName
            }
        }
    }

    # --------------------------------------------------------------------------
    # 2. CL.read.*.tlog と link.read.*.tlog の解析
    # --------------------------------------------------------------------------
    $clTlogs   = @(Get-ChildItem -LiteralPath $productDir -Filter 'CL.read.*.tlog' -File -Recurse)
    $linkTlogs = @(Get-ChildItem -LiteralPath $productDir -Filter 'link.read.*.tlog' -File -Recurse)

    foreach ($tlog in $clTlogs) {
        $content = Read-TextAutoEncoding -FilePath $tlog.FullName
        foreach ($rawLine in ($content -split '\r?\n')) {
            $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('^') -or $line.StartsWith('#')) { continue }
            $ext = [System.IO.Path]::GetExtension($line)
            if ($ext -ieq '.h' -or $ext -ieq '.hpp' -or $ext -ieq '.hxx') {
                if ($onDiskPathMap.ContainsKey($line)) {
                    $exactHeader = $onDiskPathMap[$line]
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
                    # ビルド環境パスが異なる場合、製品内の同名ヘッダを検索
                    $hLeaf = Split-Path -Path $line -Leaf
                    $foundH = @(Get-ChildItem -LiteralPath $productDir -Filter $hLeaf -File -Recurse)
                    if ($foundH.Count -gt 0 -and -not $tlogHeaders.Contains($foundH[0].FullName)) {
                        $tlogHeaders.Add($foundH[0].FullName)
                    }
                }
            }
        }
    }

    foreach ($tlog in $linkTlogs) {
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
                if (Test-Path -LiteralPath $line -PathType Leaf) {
                    $resolved = (Get-Item -LiteralPath $line).FullName
                }
                else {
                    $resolved = Resolve-DepFilePath -FileNameOrPath $leaf -BaseDir $productDir
                }
                $canonicalName = if ($null -ne $resolved) { Split-Path -Path $resolved -Leaf } else { $leaf }
                Register-Dependency -FileName $canonicalName -ResolvedPath $resolved -SourceTag 'tlog(link.read)' -ProjectName ''
            }
        }
    }

    # --------------------------------------------------------------------------
    # 3. ファイルシステム上の .lib / .dll スキャン
    # --------------------------------------------------------------------------
    $fsFiles = @(Get-ChildItem -LiteralPath $productDir -File -Recurse | Where-Object {
        $_.Extension -ieq '.lib' -or $_.Extension -ieq '.dll'
    })
    foreach ($f in $fsFiles) {
        Register-Dependency -FileName $f.Name -ResolvedPath $f.FullName -SourceTag 'FileSystem' -ProjectName ''
    }

    # --------------------------------------------------------------------------
    # 4. ヘッダファイル候補プールの構築
    # --------------------------------------------------------------------------
    $includeDirHeaders = New-Object System.Collections.Generic.List[string]
    foreach ($incDir in $includeDirs) {
        if (Test-Path -LiteralPath $incDir) {
            foreach ($h in (Get-ChildItem -LiteralPath $incDir -File -Recurse | Where-Object { $_.Extension -imatch '^\.h(?:pp|xx)?$' })) {
                if (-not $includeDirHeaders.Contains($h.FullName)) {
                    $includeDirHeaders.Add($h.FullName)
                }
            }
        }
    }
    $allProductHeaders = @(Get-ChildItem -LiteralPath $productDir -File -Recurse |
        Where-Object { $_.Extension -imatch '^\.h(?:pp|xx)?$' } |
        ForEach-Object { $_.FullName })

    # --------------------------------------------------------------------------
    # 5. 各依存ライブラリのバージョン抽出（優先順位厳守）
    #    バイナリ情報(.dll) ＞ フォルダ名 ＞ #define ＞ 改訂履歴コメント ＞ 更新日時
    # --------------------------------------------------------------------------
    $sortedDeps = $depMap.Values | Sort-Object FileType, FileName
    foreach ($dep in $sortedDeps) {
        $matchedHeader = Find-AssociatedHeader `
            -DepFileName $dep.FileName `
            -DepFullPath $dep.FullPath `
            -TlogHeaders $tlogHeaders.ToArray() `
            -IncludeDirHeaders $includeDirHeaders.ToArray() `
            -AllProductHeaders $allProductHeaders

        $verResult = $null

        # [優先順位 1] バイナリ情報 (.dll)
        if ($dep.FileType -ieq '.dll' -and -not [string]::IsNullOrWhiteSpace($dep.FullPath)) {
            $verResult = Get-BinaryDllVersion -DllPath $dep.FullPath
        }

        # [優先順位 2] フォルダ名
        if ($null -eq $verResult) {
            $pathsToCheck = New-Object System.Collections.Generic.List[string]
            if (-not [string]::IsNullOrWhiteSpace($dep.FullPath)) { $pathsToCheck.Add($dep.FullPath) }
            if (-not [string]::IsNullOrWhiteSpace($matchedHeader)) { $pathsToCheck.Add($matchedHeader) }
            if ($pathsToCheck.Count -gt 0) {
                $verResult = Get-FolderVersion -TargetPaths $pathsToCheck.ToArray() -ProductDir $productDir
            }
        }

        # [優先順位 3] #define (.h ファイル)
        if ($null -eq $verResult -and -not [string]::IsNullOrWhiteSpace($matchedHeader)) {
            $verResult = Get-HeaderDefineVersion -HeaderPath $matchedHeader
        }

        # [優先順位 4] 改訂履歴コメント (.h ファイル)
        if ($null -eq $verResult -and -not [string]::IsNullOrWhiteSpace($matchedHeader)) {
            $verResult = Get-HeaderHistoryVersion -HeaderPath $matchedHeader
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
                    Notes         = 'バージョン記載なしのためファイル更新日時へフォールバック'
                }
            }
            else {
                $verResult = [PSCustomObject]@{
                    Version       = '不明(ファイル未検出)'
                    VersionSource = '未検出'
                    Status        = '要目視確認'
                    Notes         = '実ファイルおよびヘッダが見つかりません'
                }
            }
        }

        $relFilePath = if (-not [string]::IsNullOrWhiteSpace($dep.FullPath)) {
            Get-NormalizedRelativePath -BasePath $rootFull -TargetPath $dep.FullPath
        } else { '(未解決)' }

        $relHeaderPath = if (-not [string]::IsNullOrWhiteSpace($matchedHeader)) {
            Get-NormalizedRelativePath -BasePath $rootFull -TargetPath $matchedHeader
        } else { '' }

        $projDisplay = if ($dep.Projects.Count -gt 0) {
            ($dep.Projects -join '; ')
        } else {
            '(tlog/フォルダ検出)'
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
