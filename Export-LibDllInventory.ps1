<#
.SYNOPSIS
    Windowsアプリ（C++ / .NET混在想定）の製品フォルダ配下から、依存している .lib / .dll と
    各バージョンを機械的（ルールベース：正規表現＋メタデータのみ）に抽出して
    UTF-8 (BOM付き) CSV に出力する PowerShell スクリプト。

.DESCRIPTION
    優先順位:
      1. バイナリ情報 (.dll の FileVersionInfo / PE VS_VERSION_INFO)
      2. フォルダ名 (例: ThirdParty_v2.4.1)
      3. ヘッダファイル (.h) の #define (コメントアウトされたダミー定義は除外)
      4. ヘッダファイル (.h) の改訂履歴コメント (降順 / 昇順 を自動判別、判別不能時は先頭と末尾を両方出力し「要目視確認」)
      5. ファイルの更新日時 (タイムスタンプフォールバック)

.PARAMETER InputDir
    走査対象のルートフォルダ (デフォルト: .\test_env)

.PARAMETER OutputCsv
    出力先CSVファイルパス (デフォルト: .\lib_dll_inventory.csv)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InputDir = (Join-Path $PSScriptRoot "test_env"),

    [Parameter(Mandatory = $false)]
    [string]$OutputCsv = (Join-Path $PSScriptRoot "lib_dll_inventory.csv")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SystemLibs = @(
    "kernel32.lib", "user32.lib", "gdi32.lib", "winspool.lib", "comdlg32.lib",
    "advapi32.lib", "shell32.lib", "ole32.lib", "oleaut32.lib", "uuid.lib",
    "odbc32.lib", "odbccp32.lib", "ws2_32.lib", "msvcrt.lib", "msvcrtd.lib",
    "ucrt.lib", "vcruntime.lib", "bcrypt.lib", "crypt32.lib"
)

$IgnoredDirNames = @(
    "bin", "lib", "libs", "include", "inc", "src", "ext", "thirdparty",
    "x64", "x86", "win32", "arm64", "debug", "release"
)

function Read-TextAutoEncoding {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-DllBinaryVersion {
    param([string]$DllPath)
    try {
        $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($DllPath)
        if ($fvi -and $fvi.FileVersion) {
            if ($fvi.FileVersion -match '(\d+\.\d+(?:\.\d+){0,2})') {
                if ($Matches[1] -ne "0.0.0.0") {
                    return @{ Version = $Matches[1]; Note = "PE Resource (FileVersion)" }
                }
            }
        }
    } catch {
        # 非Windows環境または標準API失敗時はバイナリ直接解析にフォールバック
    }

    $bytes = [System.IO.File]::ReadAllBytes($DllPath)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        return $null
    }

    # VS_FIXEDFILEINFO (0xFEEF04BD) の検索
    for ($i = 0; $i -le $bytes.Length - 24; $i++) {
        if ($bytes[$i] -eq 0xBD -and $bytes[$i+1] -eq 0x04 -and $bytes[$i+2] -eq 0xEF -and $bytes[$i+3] -eq 0xFE) {
            $strucVer = [System.BitConverter]::ToUInt32($bytes, $i + 4)
            if ($strucVer -eq 0x00010000) {
                $fileMs = [System.BitConverter]::ToUInt32($bytes, $i + 8)
                $fileLs = [System.BitConverter]::ToUInt32($bytes, $i + 12)
                $major = ($fileMs -shr 16) -band 0xFFFF
                $minor = $fileMs -band 0xFFFF
                $build = ($fileLs -shr 16) -band 0xFFFF
                $rev   = $fileLs -band 0xFFFF
                $verStr = "$major.$minor.$build.$rev"
                if ($verStr -ne "0.0.0.0") {
                    return @{ Version = $verStr; Note = "PE Resource (VS_FIXEDFILEINFO)" }
                }
            }
        }
    }
    return $null
}

function Get-FolderVersion {
    param([string]$FilePath, [string]$HeaderPath, [string]$StopDir)
    $stopFull = [System.IO.Path]::GetFullPath($StopDir)
    $targets = @($FilePath)
    if ($HeaderPath) { $targets += $HeaderPath }

    foreach ($t in $targets) {
        $cur = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($t))
        while ($cur -and $cur.Length -gt $stopFull.Length -and $cur.StartsWith($stopFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $dirName = [System.IO.Path]::GetFileName($cur)
            if ($IgnoredDirNames -notcontains $dirName.ToLowerInvariant() -and -not $dirName.EndsWith(".tlog", [System.StringComparison]::OrdinalIgnoreCase)) {
                if ($dirName -match '(?i)(?:^|[_\-\s.])(?:ver\.?|version\.?|rev\.?|v)(\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z._-]+)?)(?:$|[_\-\s])') {
                    return @{ Version = $Matches[1]; Note = "フォルダ '$dirName'" }
                }
                if ($dirName -match '(?:^|[_\-\s])(\d+\.\d+(?:\.\d+){1,2}(?:-[0-9A-Za-z._-]+)?)$') {
                    return @{ Version = $Matches[1]; Note = "フォルダ '$dirName'" }
                }
            }
            $cur = [System.IO.Path]::GetDirectoryName($cur)
        }
    }
    return $null
}

function Remove-CComments {
    param([string]$Code)
    $noBlock = [regex]::Replace($Code, '/\*[\s\S]*?\*/', '')
    $noLine  = [regex]::Replace($noBlock, '//[^\r\n]*', '')
    return $noLine
}

function Get-DefineVersion {
    param([string]$HeaderPath)
    $text = Read-TextAutoEncoding -Path $HeaderPath
    $active = Remove-CComments -Code $text
    $hdrName = [System.IO.Path]::GetFileName($HeaderPath)

    $singleMatch = [regex]::Match(
        $active,
        '(?im)^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*(?:VERSION|VER|REV|RELEASE)[A-Za-z0-9_]*)\s+["'']?[vV]?(\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z._-]+)?)["'']?\s*$'
    )
    if ($singleMatch.Success) {
        return @{
            Version = $singleMatch.Groups[2].Value
            Note    = "${hdrName}: #define $($singleMatch.Groups[1].Value)"
        }
    }

    $compMatches = [regex]::Matches(
        $active,
        '(?im)^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*?)_(MAJOR|MINOR|PATCH|BUILD|REVISION|REV|SUB)\s+["'']?(\d+)["'']?\s*$'
    )
    $components = @{}
    foreach ($m in $compMatches) {
        $prefix = $m.Groups[1].Value
        $part   = $m.Groups[2].Value.ToUpperInvariant()
        $val    = $m.Groups[3].Value
        if (-not $components.ContainsKey($prefix)) {
            $components[$prefix] = @{}
        }
        $components[$prefix][$part] = $val
    }
    foreach ($prefix in $components.Keys) {
        $parts = $components[$prefix]
        if ($parts.ContainsKey("MAJOR") -and $parts.ContainsKey("MINOR")) {
            $verParts = @($parts["MAJOR"], $parts["MINOR"])
            foreach ($third in @("PATCH", "BUILD", "REVISION", "REV", "SUB")) {
                if ($parts.ContainsKey($third)) {
                    $verParts += $parts[$third]
                    break
                }
            }
            return @{
                Version = ($verParts -join ".")
                Note    = "${hdrName}: #define ${prefix}_MAJOR/MINOR/..."
            }
        }
    }
    return $null
}

function Compare-IntArray {
    param([int[]]$A, [int[]]$B)
    $len = [Math]::Max($A.Length, $B.Length)
    for ($i = 0; $i -lt $len; $i++) {
        $va = if ($i -lt $A.Length) { $A[$i] } else { 0 }
        $vb = if ($i -lt $B.Length) { $B[$i] } else { 0 }
        if ($va -lt $vb) { return -1 }
        if ($va -gt $vb) { return 1 }
    }
    return 0
}

function Get-RevisionHistoryVersion {
    param([string]$HeaderPath)
    $text = Read-TextAutoEncoding -Path $HeaderPath
    $hdrName = [System.IO.Path]::GetFileName($HeaderPath)
    $blocks = [regex]::Matches($text, '/\*[\s\S]*?\*/|(?:^\s*//[^\r\n]*\r?\n?)+', [System.Text.RegularExpressions.RegexOptions]::Multiline)

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($b in $blocks) {
        $blockText = $b.Value
        $hasKeyword = $blockText -match '(?i)(?:改訂履歴|更新履歴|変更履歴|履歴|revision\s*history|update\s*history|change\s*log|history)'
        foreach ($rawLine in ($blockText -split '\r?\n')) {
            $line = ($rawLine -replace '^\s*(?:/\*+|\*+/|\*+|//+)\s*', '').Trim()
            if (-not $line) { continue }
            if ($line -match '^#\s*(?:define|include|pragma|if|ifdef|ifndef|endif|undef)\b') { continue }

            $dateMatch = [regex]::Match($line, '\b(19\d\d|20\d\d)[/\-.](0?[1-9]|1[0-2])[/\-.](0?[1-9]|[12]\d|3[01])\b')
            if ($dateMatch.Success) {
                $y = [int]$dateMatch.Groups[1].Value
                $m = [int]$dateMatch.Groups[2].Value
                $d = [int]$dateMatch.Groups[3].Value
                $dateKey = "{0:D4}{1:D2}{2:D2}" -f $y, $m, $d
                $rest = $line.Remove($dateMatch.Index, $dateMatch.Length)
                $verMatch = [regex]::Match($rest, '(?i)(?:ver\.?|version|rev\.?|v)\s*[:.]?\s*(\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z._-]+)?)\b')
                if (-not $verMatch.Success) {
                    $verMatch = [regex]::Match($rest, '(?<![0-9/.\-])(\d+\.\d+(?:\.\d+){1,2})(?![0-9/.\-])')
                }
                if ($verMatch.Success) {
                    $verStr = $verMatch.Groups[1].Value
                    $nums = [int[]]([regex]::Matches($verStr, '\d+') | ForEach-Object { [int]$_.Value })
                    $entries.Add([PSCustomObject]@{
                        Version = $verStr
                        VerNums = $nums
                        DateKey = $dateKey
                        RawDate = $dateMatch.Value
                    })
                }
            } elseif ($hasKeyword) {
                $verMatch = [regex]::Match($line, '(?i)(?:ver\.?|version|rev\.?|v)\s*[:.]?\s*(\d+\.\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z._-]+)?)\b')
                if ($verMatch.Success) {
                    $verStr = $verMatch.Groups[1].Value
                    $nums = [int[]]([regex]::Matches($verStr, '\d+') | ForEach-Object { [int]$_.Value })
                    $entries.Add([PSCustomObject]@{
                        Version = $verStr
                        VerNums = $nums
                        DateKey = $null
                        RawDate = $null
                    })
                }
            }
        }
    }

    if ($entries.Count -eq 0) { return $null }
    if ($entries.Count -eq 1) {
        return @{
            Version = $entries[0].Version
            Source  = "改訂履歴コメント"
            Status  = "OK"
            Note    = "${hdrName}: 履歴1件 ($($entries[0].Version))"
        }
    }

    $allHaveDates = ($entries | Where-Object { $null -eq $_.DateKey }).Count -eq 0
    if ($allHaveDates) {
        $datesAsc  = $true
        $datesDesc = $true
        $versAsc   = $true
        $versDesc  = $true
        for ($i = 0; $i -lt $entries.Count - 1; $i++) {
            if ($entries[$i].DateKey -gt $entries[$i+1].DateKey) { $datesAsc = $false }
            if ($entries[$i].DateKey -lt $entries[$i+1].DateKey) { $datesDesc = $false }
            $cmp = Compare-IntArray -A $entries[$i].VerNums -B $entries[$i+1].VerNums
            if ($cmp -gt 0) { $versAsc = $false }
            if ($cmp -lt 0) { $versDesc = $false }
        }
        $first = $entries[0]
        $last  = $entries[$entries.Count - 1]
        if ($datesAsc -and ($first.DateKey -lt $last.DateKey) -and $versAsc) {
            return @{
                Version = $last.Version
                Source  = "改訂履歴コメント(昇順)"
                Status  = "OK"
                Note    = "${hdrName}: 全$($entries.Count)件: 先頭=$($first.Version)($($first.RawDate)) -> 末尾(最新)=$($last.Version)($($last.RawDate))"
            }
        }
        if ($datesDesc -and ($first.DateKey -gt $last.DateKey) -and $versDesc) {
            return @{
                Version = $first.Version
                Source  = "改訂履歴コメント(降順)"
                Status  = "OK"
                Note    = "${hdrName}: 全$($entries.Count)件: 先頭(最新)=$($first.Version)($($first.RawDate)) <- 末尾=$($last.Version)($($last.RawDate))"
            }
        }
    }

    $firstVer = $entries[0].Version
    $lastVer  = $entries[$entries.Count - 1].Version
    return @{
        Version = "先頭: $firstVer / 末尾: $lastVer"
        Source  = "改訂履歴コメント(順序不明)"
        Status  = "要目視確認"
        Note    = "${hdrName}: 全$($entries.Count)件の履歴の昇順・降順が判別不能なため先頭と末尾を出力"
    }
}

Write-Host "[INFO] 対象ディレクトリ: $InputDir"
Write-Host "[INFO] Python版 (export_lib_dll_inventory.py) と同一ルールで抽出を行います。"

$rootFull = [System.IO.Path]::GetFullPath($InputDir)
$allFiles = Get-ChildItem -Path $rootFull -Recurse -File
$fileIndex = @{}
foreach ($f in $allFiles) {
    $k = $f.Name.ToLowerInvariant()
    if (-not $fileIndex.ContainsKey($k)) { $fileIndex[$k] = New-Object System.Collections.Generic.List[string] }
    $fileIndex[$k].Add($f.FullName)
}

function Resolve-TargetFile {
    param([string]$RawPath, [string]$BaseDir)
    $cleaned = $RawPath.Trim().Trim('"').Replace('$(ProjectDir)', '')
    if (-not $cleaned -or $cleaned.StartsWith('%(')) { return $null }
    $norm = $cleaned.Replace('\', '/')
    $baseName = [System.IO.Path]::GetFileName($norm).ToLowerInvariant()
    if ($SystemLibs -contains $baseName) { return $null }
    if ($norm -match '(?i)(program files|/windows kits/|c:/windows/)') { return $null }

    $direct = [System.IO.Path]::GetFullPath((Join-Path $BaseDir $norm))
    if ([System.IO.File]::Exists($direct)) { return $direct }

    if (-not $fileIndex.ContainsKey($baseName)) { return $null }
    $cands = $fileIndex[$baseName]
    if ($cands.Count -eq 1) { return $cands[0] }
    foreach ($c in $cands) {
        if ($c.StartsWith($BaseDir, [System.StringComparison]::OrdinalIgnoreCase)) { return $c }
    }
    return $cands[0]
}

$csvRows = New-Object System.Collections.Generic.List[object]
$productDirs = Get-ChildItem -Path $rootFull -Directory | Sort-Object Name

foreach ($prodDir in $productDirs) {
    $prodName = $prodDir.Name
    $records = @{}
    $tlogHeaders = New-Object System.Collections.Generic.List[string]

    function Register-Dep {
        param([string]$Path, [string]$Label)
        $nameLower = [System.IO.Path]::GetFileName($Path).ToLowerInvariant()
        if ($SystemLibs -contains $nameLower) { return }
        if (-not $records.ContainsKey($Path)) {
            $rel = $Path.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
            $records[$Path] = [PSCustomObject]@{
                Product      = $prodName
                FilePath     = $Path
                FileName     = [System.IO.Path]::GetFileName($Path)
                FileType     = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
                RelativePath = $rel
                DetectedIn   = New-Object System.Collections.Generic.List[string]
            }
        }
        if (-not $records[$Path].DetectedIn.Contains($Label)) {
            $records[$Path].DetectedIn.Add($Label)
        }
    }

    # .vcxproj 解析
    $vcxprojList = Get-ChildItem -Path $prodDir.FullName -Filter "*.vcxproj" -Recurse -File
    foreach ($vcx in $vcxprojList) {
        if ($vcx.DirectoryName -ne $prodDir.FullName -and $vcxprojList.Count -gt 1) { continue }
        [xml]$xml = Read-TextAutoEncoding -Path $vcx.FullName
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace("ms", "http://schemas.microsoft.com/developer/msbuild/2003")

        foreach ($node in $xml.SelectNodes("//ms:AdditionalDependencies", $ns)) {
            foreach ($tok in ($node.InnerText -split ';')) {
                $r = Resolve-TargetFile -RawPath $tok -BaseDir $vcx.DirectoryName
                if ($r) { Register-Dep -Path $r -Label "$($vcx.Name)(AdditionalDependencies)" }
            }
        }
        foreach ($node in $xml.SelectNodes("//ms:Reference/ms:HintPath", $ns)) {
            $r = Resolve-TargetFile -RawPath $node.InnerText -BaseDir $vcx.DirectoryName
            if ($r) { Register-Dep -Path $r -Label "$($vcx.Name)(Reference/HintPath)" }
        }
        foreach ($node in $xml.SelectNodes("//ms:ProjectReference", $ns)) {
            $inc = $node.GetAttribute("Include")
            $refVcx = Resolve-TargetFile -RawPath $inc -BaseDir $vcx.DirectoryName
            if ($refVcx) {
                $refStem = [System.IO.Path]::GetFileNameWithoutExtension($refVcx)
                $refDir  = [System.IO.Path]::GetDirectoryName($refVcx)
                foreach ($sub in (Get-ChildItem -Path $refDir -Recurse -File)) {
                    if ($sub.Extension -match '(?i)^\.(lib|dll)$' -and $sub.BaseName -ieq $refStem) {
                        Register-Dep -Path $sub.FullName -Label "$($vcx.Name)(ProjectReference)"
                    }
                }
            }
        }
    }

    # .tlog 解析
    foreach ($tlog in (Get-ChildItem -Path $prodDir.FullName -Filter "link.read.*.tlog" -Recurse -File)) {
        foreach ($line in ((Read-TextAutoEncoding -Path $tlog.FullName) -split '\r?\n')) {
            $l = $line.Trim()
            if (-not $l -or $l.StartsWith('^')) { continue }
            if ($l -match '(?i)\.(lib|dll)$') {
                $r = Resolve-TargetFile -RawPath $l -BaseDir $prodDir.FullName
                if ($r) { Register-Dep -Path $r -Label $tlog.Name }
            }
        }
    }
    foreach ($tlog in (Get-ChildItem -Path $prodDir.FullName -Filter "CL.read.*.tlog" -Recurse -File)) {
        foreach ($line in ((Read-TextAutoEncoding -Path $tlog.FullName) -split '\r?\n')) {
            $l = $line.Trim()
            if (-not $l -or $l.StartsWith('^')) { continue }
            if ($l -match '(?i)\.(h|hpp)$') {
                $r = Resolve-TargetFile -RawPath $l -BaseDir $prodDir.FullName
                if ($r -and -not $tlogHeaders.Contains($r)) { $tlogHeaders.Add($r) }
            }
        }
    }

    # ディレクトリ走査
    foreach ($f in (Get-ChildItem -Path $prodDir.FullName -Recurse -File)) {
        if ($f.Extension -match '(?i)^\.(lib|dll)$') {
            Register-Dep -Path $f.FullName -Label "DirectoryScan"
        }
    }

    $sortedRecs = $records.Values | Sort-Object FileType, FileName
    foreach ($rec in $sortedRecs) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($rec.FileName)
        $hdrPath = $null
        foreach ($h in $tlogHeaders) {
            if ([System.IO.Path]::GetFileNameWithoutExtension($h) -ieq $stem) { $hdrPath = $h; break }
        }
        if (-not $hdrPath -and $fileIndex.ContainsKey("$($stem.ToLowerInvariant()).h")) {
            $hdrPath = $fileIndex["$($stem.ToLowerInvariant()).h"][0]
        }

        $ver = ""; $src = ""; $status = "OK"; $note = ""
        if ($rec.FileType -eq ".dll") {
            $res = Get-DllBinaryVersion -DllPath $rec.FilePath
            if ($res) { $ver = $res.Version; $src = "バイナリ情報(.dll)"; $note = $res.Note }
        }
        if (-not $ver) {
            $res = Get-FolderVersion -FilePath $rec.FilePath -HeaderPath $hdrPath -StopDir $rootFull
            if ($res) { $ver = $res.Version; $src = "フォルダ名"; $note = $res.Note }
        }
        if (-not $ver -and $hdrPath) {
            $res = Get-DefineVersion -HeaderPath $hdrPath
            if ($res) { $ver = $res.Version; $src = "#define"; $note = $res.Note }
        }
        if (-not $ver -and $hdrPath) {
            $res = Get-RevisionHistoryVersion -HeaderPath $hdrPath
            if ($res) { $ver = $res.Version; $src = $res.Source; $status = $res.Status; $note = $res.Note }
        }
        if (-not $ver) {
            $dt = (Get-Item $rec.FilePath).LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            $ver = $dt; $src = "更新日時"; $note = "$($rec.FileName) の更新日時"
        }

        $hdrRel = if ($hdrPath) { $hdrPath.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/') } else { "-" }
        $csvRows.Add([PSCustomObject]@{
            Product       = $rec.Product
            FileName      = $rec.FileName
            FileType      = $rec.FileType
            RelativePath  = $rec.RelativePath
            DetectedIn    = ($rec.DetectedIn -join "; ")
            HeaderFile    = $hdrRel
            Version       = $ver
            VersionSource = $src
            Status        = $status
            Notes         = $note
        })
    }
}

# UTF-8 (BOM付き) で CSV 出力
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$sw = New-Object System.IO.StreamWriter($OutputCsv, $false, $utf8Bom)
try {
    $csvText = ($csvRows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
    $sw.WriteLine($csvText)
} finally {
    $sw.Dispose()
}

Write-Host "[INFO] 抽出完了: $($csvRows.Count) 件を '$OutputCsv' (UTF-8 BOM付き) に出力しました。"
$csvRows | Format-Table Product, FileName, Version, VersionSource, Status -AutoSize
