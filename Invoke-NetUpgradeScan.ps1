<#
.SYNOPSIS
    NetUpgradeLab Scanner - a read-only report of what needs attention before upgrading a .NET solution to .NET 10.

.DESCRIPTION
    Scans a folder (usually a repository root) and reports:
      - every project: SDK-style or legacy, target framework(s), upgrade category
      - NuGet packages: Microsoft packages below 10.x, missing versions, known deprecated packages, packages.config
      - code patterns that are obsolete or removed in .NET 9 / .NET 10
      - pinned SDK versions in global.json, Dockerfiles and CI pipelines

    The scanner never modifies any file. It only reads project, code and config files.

.PARAMETER Path
    Folder to scan. Defaults to the current folder.

.PARAMETER OutFile
    Path of the Markdown report. Defaults to netupgrade-report.md in the current folder.

.PARAMETER Json
    Also write the raw results as JSON next to the Markdown report.

.EXAMPLE
    ./Invoke-NetUpgradeScan.ps1 -Path C:\src\MySolution

.NOTES
    NetUpgradeLab by Northbyte Lab - https://github.com/northbytelab
    License: MIT
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Path = '.',
    [string]$OutFile = 'netupgrade-report.md',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScannerVersion = '1.0.0'
$TargetMajor = 10

# --------------------------------------------------------------------------------------------
# Rules
# --------------------------------------------------------------------------------------------

# Packages that are deprecated or need attention when moving to .NET 10.
$PackageRules = @(
    @{ Name = 'Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation'; Note = 'Razor runtime compilation is obsolete in ASP.NET Core 10. Use build-time compilation and Hot Reload.' }
    @{ Name = 'Microsoft.Extensions.ApiDescription.Client';        Note = 'Package is deprecated in ASP.NET Core 10.' }
    @{ Name = 'Microsoft.AspNetCore.JsonPatch';                    Note = 'ASP.NET Core 10 adds a System.Text.Json based JSON Patch package. Review if you rely on Newtonsoft-based JSON Patch.' }
    @{ Name = 'System.Runtime.Serialization.Formatters';           Note = 'BinaryFormatter was removed from the runtime in .NET 9. Plan a replacement serializer.' }
)

# Code patterns (regex) that are obsolete, removed or changed in .NET 9 / 10.
$CodeRules = @(
    @{ Id = 'WEBHOST';      Pattern = '\bWebHost\.CreateDefaultBuilder\b|\bnew\s+WebHostBuilder\b|\bIWebHost\b'; Note = 'WebHostBuilder, IWebHost and WebHost are obsolete in .NET 10. Move to WebApplication.CreateBuilder or the generic host.' }
    @{ Id = 'ACTIONCTX';    Pattern = '\bI?ActionContextAccessor\b';                                           Note = 'IActionContextAccessor / ActionContextAccessor are obsolete in .NET 10. Use IHttpContextAccessor.' }
    @{ Id = 'WITHOPENAPI';  Pattern = '\.WithOpenApi\s*\(';                                                    Note = 'WithOpenApi() is deprecated in .NET 10. The built-in generator emits OpenAPI 3.1 by default.' }
    @{ Id = 'KNOWNNETS';    Pattern = '\bKnownNetworks\b';                                                     Note = 'ForwardedHeadersOptions.KnownNetworks is obsolete in .NET 10. Use KnownIpNetworks.' }
    @{ Id = 'RAZORRUNTIME'; Pattern = '\bAddRazorRuntimeCompilation\s*\(';                                     Note = 'Razor runtime compilation is obsolete in .NET 10.' }
    @{ Id = 'BINARYFMT';    Pattern = '\bBinaryFormatter\b';                                                   Note = 'BinaryFormatter was removed from the runtime in .NET 9 and throws at runtime.' }
    @{ Id = 'SYSTEMWEB';    Pattern = '^\s*using\s+System\.Web(\.|;)';                                         Note = 'System.Web does not exist in modern .NET. This code needs migration (ASP.NET Core).' }
)

$ExcludedDirs = @('bin', 'obj', 'node_modules', '.git', '.vs', 'packages', 'TestResults')

# --------------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------------

function Test-Excluded([string]$FullName) {
    $parts = $FullName -split '[\\/]'
    foreach ($p in $parts) { if ($ExcludedDirs -contains $p) { return $true } }
    return $false
}

function Get-Files([string]$Root, [string[]]$Include) {
    Get-ChildItem -Path $Root -Recurse -File -Force -Include $Include -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-Excluded $_.FullName) }
}

function Get-RelPath([string]$Root, [string]$FullName) {
    [System.IO.Path]::GetRelativePath($Root, $FullName) -replace '\\', '/'
}

function Get-Major([string]$Version) {
    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    $m = [regex]::Match($Version, '\d+')
    if ($m.Success) { return [int]$m.Value }
    return $null
}

function Get-TfmMajor([string]$Tfm) {
    # net8.0 -> 8, net10.0-windows -> 10, netcoreapp3.1 -> 3, net48 -> 48 (Framework, handled separately)
    $m = [regex]::Match($Tfm, '^net(coreapp)?(\d+)\.(\d+)')
    if ($m.Success) { return [int]$m.Groups[2].Value }
    return $null
}

function Get-Category([string[]]$Tfms, [bool]$IsSdkStyle) {
    if (-not $IsSdkStyle) { return 'Migration' }
    $cats = foreach ($t in $Tfms) {
        if ($t -match '^netstandard') { 'Library (netstandard)' }
        elseif ($t -match '^net\d{2,3}$') { 'Migration' }               # net48, net472 ...
        elseif ($t -match '^netcoreapp') { 'Upgrade' }
        else {
            $major = Get-TfmMajor $t
            if ($null -eq $major) { 'Unknown' }
            elseif ($major -ge $TargetMajor) { 'Ready' }
            else { 'Upgrade' }
        }
    }
    foreach ($c in 'Migration', 'Upgrade', 'Unknown', 'Library (netstandard)', 'Ready') {
        if ($cats -contains $c) { return $c }
    }
    return 'Unknown'
}

function Get-XmlValue($Xml, [string]$XPath) {
    $nodes = $Xml.SelectNodes($XPath)
    if ($null -eq $nodes -or $nodes.Count -eq 0) { return $null }
    return ($nodes | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ }) -join ';'
}

# --------------------------------------------------------------------------------------------
# Scan
# --------------------------------------------------------------------------------------------

$Root = (Resolve-Path -LiteralPath $Path).Path
Write-Host ''
Write-Host "NetUpgradeLab Scanner v$ScannerVersion" -ForegroundColor Magenta
Write-Host "Scanning $Root (read-only)..." -ForegroundColor DarkGray

# Central Package Management
$cpmVersions = @{}
$cpmFiles = Get-Files $Root @('Directory.Packages.props')
foreach ($f in $cpmFiles) {
    try {
        [xml]$x = Get-Content -LiteralPath $f.FullName -Raw
        foreach ($pv in $x.SelectNodes('//*[local-name()="PackageVersion"]')) {
            $name = $pv.GetAttribute('Include')
            $ver = $pv.GetAttribute('Version')
            if ($name) { $cpmVersions[$name] = $ver }
        }
    } catch { Write-Warning "Could not read $($f.FullName): $($_.Exception.Message)" }
}

# Directory.Build.props target framework (common in larger solutions)
$buildPropsTfm = $null
foreach ($f in (Get-Files $Root @('Directory.Build.props'))) {
    try {
        [xml]$x = Get-Content -LiteralPath $f.FullName -Raw
        $t = Get-XmlValue $x '//*[local-name()="TargetFramework" or local-name()="TargetFrameworks"]'
        if ($t) { $buildPropsTfm = $t }
    } catch { }
}

# Projects
$projects = @()
$packageFindings = @()
$projectFiles = Get-Files $Root @('*.csproj', '*.fsproj', '*.vbproj')

foreach ($pf in $projectFiles) {
    $rel = Get-RelPath $Root $pf.FullName
    try {
        [xml]$x = Get-Content -LiteralPath $pf.FullName -Raw
    } catch {
        $projects += [pscustomobject]@{ Project = $rel; Style = '?'; TargetFrameworks = '?'; Category = 'Unknown'; Notes = 'Could not parse project file.' }
        continue
    }

    $projectNode = $x.SelectSingleNode('/*[local-name()="Project"]')
    $sdkAttr = if ($projectNode) { $projectNode.GetAttribute('Sdk') } else { '' }
    $hasSdkElement = $null -ne $x.SelectSingleNode('//*[local-name()="Sdk"]')
    $isSdkStyle = [bool]$sdkAttr -or $hasSdkElement

    $notes = @()
    if ($isSdkStyle) {
        $tfmText = Get-XmlValue $x '//*[local-name()="TargetFramework" or local-name()="TargetFrameworks"]'
        if (-not $tfmText -and $buildPropsTfm) { $tfmText = $buildPropsTfm; $notes += 'TFM from Directory.Build.props' }
        $tfms = @(($tfmText -split ';') | Where-Object { $_ })
    } else {
        $fv = Get-XmlValue $x '//*[local-name()="TargetFrameworkVersion"]'
        $tfms = @(if ($fv) { ".NET Framework $($fv.TrimStart('v'))" } else { '.NET Framework (unknown)' })
        $notes += 'Legacy (non SDK-style) project file'
    }

    $packagesConfig = Join-Path $pf.DirectoryName 'packages.config'
    if (Test-Path -LiteralPath $packagesConfig) { $notes += 'Uses packages.config' }

    $category = Get-Category $tfms $isSdkStyle
    $projects += [pscustomobject]@{
        Project          = $rel
        Style            = if ($isSdkStyle) { 'SDK' } else { 'Legacy' }
        TargetFrameworks = ($tfms -join ', ')
        Category         = $category
        Notes            = ($notes -join '; ')
    }

    # Packages
    foreach ($pr in $x.SelectNodes('//*[local-name()="PackageReference"]')) {
        $name = $pr.GetAttribute('Include')
        if (-not $name) { $name = $pr.GetAttribute('Update') }
        if (-not $name) { continue }
        $ver = $pr.GetAttribute('Version')
        if (-not $ver) {
            $vNode = $pr.SelectSingleNode('*[local-name()="Version"]')
            if ($vNode) { $ver = $vNode.InnerText.Trim() }
        }
        $fromCpm = $false
        if (-not $ver -and $cpmVersions.ContainsKey($name)) { $ver = $cpmVersions[$name]; $fromCpm = $true }

        if (-not $ver) {
            $packageFindings += [pscustomobject]@{ Project = $rel; Package = $name; Version = '(none)'; Issue = 'PackageReference without a version is an error in the .NET 10 SDK (unless managed centrally).' }
            continue
        }

        $ruleHit = $false
        foreach ($rule in $PackageRules) {
            if ($name -ieq $rule.Name) {
                $packageFindings += [pscustomobject]@{ Project = $rel; Package = $name; Version = $ver; Issue = $rule.Note }
                $ruleHit = $true
            }
        }
        if ($ruleHit) { continue }

        $major = Get-Major $ver
        $isMsPlatform = $name -match '^(Microsoft\.AspNetCore\.|Microsoft\.Extensions\.|Microsoft\.EntityFrameworkCore)'
        if ($isMsPlatform -and $null -ne $major -and $major -lt $TargetMajor -and $category -ne 'Library (netstandard)') {
            $packageFindings += [pscustomobject]@{ Project = $rel; Package = $name; Version = $ver; Issue = "Platform package below $TargetMajor.x. Update to $TargetMajor.0.x together with the target framework." + $(if ($fromCpm) { ' (version from Directory.Packages.props)' } else { '' }) }
        }
    }
}

# Code patterns
$codeFindings = @()
$codeFiles = Get-Files $Root @('*.cs')
foreach ($cf in $codeFiles) {
    $rel = Get-RelPath $Root $cf.FullName
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($cf.FullName)) {
        $lineNo++
        $trim = $line.TrimStart()
        if ($trim.StartsWith('//')) { continue }
        foreach ($rule in $CodeRules) {
            if ($line -match $rule.Pattern) {
                $codeFindings += [pscustomobject]@{ Rule = $rule.Id; File = $rel; Line = $lineNo; Note = $rule.Note }
            }
        }
    }
}

# Legacy ASP.NET markers
$legacyMarkers = @(Get-Files $Root @('Global.asax', '*.aspx', '*.svc') | ForEach-Object { Get-RelPath $Root $_.FullName })

# global.json
$sdkPins = @()
foreach ($g in (Get-Files $Root @('global.json'))) {
    try {
        $j = Get-Content -LiteralPath $g.FullName -Raw | ConvertFrom-Json
        $v = if ($j.PSObject.Properties['sdk'] -and $j.sdk.PSObject.Properties['version']) { $j.sdk.version } else { '(none)' }
        $sdkPins += [pscustomobject]@{ Where = Get-RelPath $Root $g.FullName; Kind = 'global.json'; Version = $v; NeedsUpdate = ((Get-Major $v) -lt $TargetMajor) }
    } catch { Write-Warning "Could not parse $($g.FullName)" }
}

# Dockerfiles
foreach ($d in (Get-Files $Root @('Dockerfile', 'Dockerfile.*', '*.Dockerfile'))) {
    $rel = Get-RelPath $Root $d.FullName
    foreach ($line in [System.IO.File]::ReadLines($d.FullName)) {
        $m = [regex]::Match($line, 'mcr\.microsoft\.com/dotnet/(?:core/)?(sdk|aspnet|runtime|runtime-deps):([\w\.\-]+)', 'IgnoreCase')
        if ($m.Success) {
            $tag = $m.Groups[2].Value
            $sdkPins += [pscustomobject]@{ Where = $rel; Kind = "Docker image ($($m.Groups[1].Value))"; Version = $tag; NeedsUpdate = ((Get-Major $tag) -lt $TargetMajor) }
        }
    }
}

# CI pipelines
$ciFiles = @(Get-Files $Root @('*.yml', '*.yaml') | Where-Object { $_.FullName -match '[\\/]\.github[\\/]workflows[\\/]' -or $_.Name -match '^azure-pipelines' })
foreach ($c in $ciFiles) {
    $rel = Get-RelPath $Root $c.FullName
    $isAzure = $c.Name -match '^azure-pipelines'
    if ($isAzure -and -not (Select-String -LiteralPath $c.FullName -Pattern 'UseDotNet' -Quiet)) { continue }
    $pinPattern = if ($isAzure) { '^\s*version\s*:\s*[''"]?(\d+(\.\d+|\.x)*)' } else { '(?<![\w-])dotnet-version\s*:\s*[''"]?(\d+(\.\d+|\.x)*)' }
    foreach ($line in [System.IO.File]::ReadLines($c.FullName)) {
        $m = [regex]::Match($line, $pinPattern)
        if ($m.Success) {
            $v = $m.Groups[1].Value
            $sdkPins += [pscustomobject]@{ Where = $rel; Kind = 'CI pipeline'; Version = $v; NeedsUpdate = ((Get-Major $v) -lt $TargetMajor) }
        }
    }
}

# --------------------------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------------------------

function Get-Count($Items, [scriptblock]$Filter) { @($Items | Where-Object $Filter).Count }

$summary = [ordered]@{
    Projects          = $projects.Count
    Ready             = Get-Count $projects { $_.Category -eq 'Ready' }
    NeedUpgrade       = Get-Count $projects { $_.Category -eq 'Upgrade' }
    NeedMigration     = Get-Count $projects { $_.Category -eq 'Migration' }
    NetStandardLibs   = Get-Count $projects { $_.Category -eq 'Library (netstandard)' }
    PackageFindings   = $packageFindings.Count
    CodeFindings      = $codeFindings.Count
    PinsToUpdate      = Get-Count $sdkPins { $_.NeedsUpdate }
    LegacyAspNetFiles = $legacyMarkers.Count
}

function Esc([string]$s) { ($s -replace '\|', '\|') }

$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# .NET 10 Upgrade Report')
$md.Add('')
$md.Add("Generated by NetUpgradeLab Scanner v$ScannerVersion on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). The scan is read-only and covers the folder: ``$(Split-Path $Root -Leaf)``.")
$md.Add('')
$md.Add('## Summary')
$md.Add('')
$md.Add('| Item | Count |')
$md.Add('| --- | --- |')
$md.Add("| Projects found | $($summary.Projects) |")
$md.Add("| Already on .NET $TargetMajor+ | $($summary.Ready) |")
$md.Add("| Need a version upgrade (.NET Core / .NET 5-9) | $($summary.NeedUpgrade) |")
$md.Add("| Need a migration (.NET Framework / legacy project) | $($summary.NeedMigration) |")
$md.Add("| .NET Standard libraries (usually fine as-is) | $($summary.NetStandardLibs) |")
$md.Add("| Package findings | $($summary.PackageFindings) |")
$md.Add("| Code findings | $($summary.CodeFindings) |")
$md.Add("| SDK / Docker / CI pins to update | $($summary.PinsToUpdate) |")
$md.Add("| Legacy ASP.NET files (Web Forms, WCF, Global.asax) | $($summary.LegacyAspNetFiles) |")
$md.Add('')

$md.Add('## Projects')
$md.Add('')
if ($projects.Count -eq 0) { $md.Add('No project files found.') } else {
    $md.Add('| Project | Style | Target framework(s) | Category | Notes |')
    $md.Add('| --- | --- | --- | --- | --- |')
    $order = @{ 'Migration' = 0; 'Upgrade' = 1; 'Unknown' = 2; 'Library (netstandard)' = 3; 'Ready' = 4 }
    foreach ($p in ($projects | Sort-Object @{ Expression = { $order[$_.Category] } }, Project)) {
        $md.Add("| $(Esc $p.Project) | $($p.Style) | $(Esc $p.TargetFrameworks) | $($p.Category) | $(Esc $p.Notes) |")
    }
}
$md.Add('')

$md.Add('## Packages')
$md.Add('')
if ($packageFindings.Count -eq 0) { $md.Add('No package issues found.') } else {
    $md.Add('| Project | Package | Version | What to check |')
    $md.Add('| --- | --- | --- | --- |')
    foreach ($f in ($packageFindings | Sort-Object Project, Package)) {
        $md.Add("| $(Esc $f.Project) | $(Esc $f.Package) | $(Esc $f.Version) | $(Esc $f.Issue) |")
    }
}
$md.Add('')
$md.Add('Third-party packages are not checked against NuGet. Run `dotnet list package --outdated` and `dotnet list package --vulnerable` for a full picture.')
$md.Add('')

$md.Add('## Code')
$md.Add('')
if ($codeFindings.Count -eq 0) { $md.Add('No known obsolete patterns found.') } else {
    $md.Add('| File | Line | What to check |')
    $md.Add('| --- | --- | --- |')
    foreach ($f in ($codeFindings | Sort-Object File, Line)) {
        $md.Add("| $(Esc $f.File) | $($f.Line) | $(Esc $f.Note) |")
    }
}
$md.Add('')
$md.Add('Pattern matching finds likely spots, not every breaking change. Building with `-warnaserror` against the .NET 10 SDK surfaces the rest.')
$md.Add('')

$md.Add('## SDK, Docker and CI pins')
$md.Add('')
if ($sdkPins.Count -eq 0) { $md.Add('No global.json, Docker images or CI SDK versions found.') } else {
    $md.Add('| Where | Kind | Version | Update needed |')
    $md.Add('| --- | --- | --- | --- |')
    foreach ($s in $sdkPins) {
        $md.Add("| $(Esc $s.Where) | $($s.Kind) | $(Esc $s.Version) | $(if ($s.NeedsUpdate) { 'Yes' } else { 'No' }) |")
    }
    $md.Add('')
    $md.Add("Note: default .NET $TargetMajor container images are based on Ubuntu. Check Dockerfiles that install Debian packages.")
}
$md.Add('')

if ($legacyMarkers.Count -gt 0) {
    $md.Add('## Legacy ASP.NET files')
    $md.Add('')
    $md.Add('These have no direct equivalent in modern .NET and usually need a partial rewrite (for example Razor Pages or Blazor for Web Forms, CoreWCF or gRPC for WCF).')
    $md.Add('')
    foreach ($l in $legacyMarkers) { $md.Add("- $l") }
    $md.Add('')
}

$md.Add('---')
$md.Add('')
$md.Add('Need a hand with the upgrade? **NetUpgradeLab** helps teams move to .NET 10: labnorthbyte@gmail.com')
$md.Add('')

$outPath = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Get-Location).Path $OutFile }
[System.IO.File]::WriteAllLines($outPath, $md)

if ($Json) {
    $jsonPath = [System.IO.Path]::ChangeExtension($outPath, '.json')
    [ordered]@{
        scannerVersion = $ScannerVersion
        root           = $Root
        summary        = $summary
        projects       = $projects
        packages       = $packageFindings
        code           = $codeFindings
        pins           = $sdkPins
        legacyFiles    = $legacyMarkers
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding utf8
}

# Console summary
Write-Host ''
Write-Host "Projects: $($summary.Projects)  |  ready: $($summary.Ready)  |  upgrade: $($summary.NeedUpgrade)  |  migration: $($summary.NeedMigration)" -ForegroundColor White
$color = if (($summary.PackageFindings + $summary.CodeFindings + $summary.PinsToUpdate) -gt 0) { 'Yellow' } else { 'Green' }
Write-Host "Findings: $($summary.PackageFindings) package, $($summary.CodeFindings) code, $($summary.PinsToUpdate) SDK/Docker/CI pins" -ForegroundColor $color
Write-Host "Report:   $outPath" -ForegroundColor Cyan
Write-Host ''
Write-Host 'Need a hand with the upgrade? NetUpgradeLab -> labnorthbyte@gmail.com' -ForegroundColor DarkGray
Write-Host ''
