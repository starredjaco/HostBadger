<#
.SYNOPSIS
    Says whether the framework data HostBadger ships (DISA STIG, CIS, Essential Eight, ACN) is still
    the newest one you have, and whether the shipped data still matches the converters.

.DESCRIPTION
    Developer tool for a release, not part of a HostBadger run and never loaded by it: it reads local
    files only and downloads nothing, like the converters next to it. The "newer version available"
    question is a maintainer's question, not a finding about a host, so it lives here and nothing in a
    report or a snapshot depends on it.

    What it compares:

    - data\stig-catalog.json carries the PowerSTIG file and the STIG version and release (V2R7) each
      product was built from. Against -StigDir (your local clone of PowerSTIG's
      source/StigData/Processed) it reports a newer version.release of the same product, and it always
      reports a product whose file differs from the -Files defaults of Convert-PowerStigData.ps1 (the
      catalog and the converter would then disagree about what HostBadger ships).
    - data\cis-map.json carries the benchmark version of each CIS benchmark the rule numbers come from.
      Against -CisDir (the folder holding your ansible-lockdown Windows-*-CIS clones) it reports the
      benchmark versions those clones name, when their README says so.
    - The ASD Essential Eight model release and the ACN determination are written in the code and in
      data\acn-nis2-measures.json and have no local source to compare against: they are printed as a
      reminder to check them by hand (ACSC and ACN publish them as documents, not as data).

    Nothing is written. Read the lines marked CHECK.

.PARAMETER StigDir
    PowerSTIG processed XML folder (source/StigData/Processed of a PowerSTIG clone). Optional.
.PARAMETER CisDir
    Folder holding the ansible-lockdown Windows-11-CIS, Windows-10-CIS, Windows-2022-CIS,
    Windows-2019-CIS and Windows-2016-CIS clones. Optional.
.EXAMPLE
    .\tools\Test-CatalogVersions.ps1 -StigDir C:\src\PowerSTIG\source\StigData\Processed
#>
[CmdletBinding()]
param(
    [string]$StigDir = '',
    [string]$CisDir = '',
    [string]$Root = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Stop'

function Get-FileRelease {
    # 'WindowsClient-11-2.7.xml' -> @{ Prefix = 'WindowsClient-11'; V = 2; R = 7 }. $null when the name
    # does not end in <version>.<release>.xml.
    param([string]$Name)
    $m = [regex]::Match("$Name", '^(?<p>.+)-(?<v>\d+)\.(?<r>\d+)\.xml$')
    if (-not $m.Success) { return $null }
    return @{ Prefix = $m.Groups['p'].Value; V = [int]$m.Groups['v'].Value; R = [int]$m.Groups['r'].Value }
}

$notes = New-Object System.Collections.Generic.List[string]
$checks = 0

# ---------------------------------------------------------------- DISA STIG
$catPath = Join-Path $Root 'data\stig-catalog.json'
$cat = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($catPath))
if (-not $cat.PSObject.Properties['releases']) {
    $notes.Add('CHECK  stig-catalog.json has no "releases": rebuild it with tools\Convert-PowerStigData.ps1.')
    $checks++
}
else {
    "DISA STIG catalog built on $($cat.built), $(@($cat.rules).Count) registry rules."
    # The converter's own defaults: the catalog should come from exactly those files.
    $conv = Join-Path $Root 'tools\Convert-PowerStigData.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($conv, [ref]$null, [ref]$null)
    $filesParam = @($ast.ParamBlock.Parameters | Where-Object { "$($_.Name)" -eq '$Files' })
    $defaults = if ($filesParam.Count -eq 1 -and $filesParam[0].DefaultValue) { & ([scriptblock]::Create($filesParam[0].DefaultValue.Extent.Text)) } else { @{} }
    foreach ($p in @($cat.releases.PSObject.Properties.Name | Sort-Object)) {
        $have = "$($cat.releases.$p.file)"
        $rel = "$($cat.releases.$p.release)"
        $want = "$($defaults[$p])"
        $line = "  {0,-12} {1,-6} {2}" -f $p, $rel, $have
        if ($want -and $want -ne $have) {
            $notes.Add("CHECK  $p`: the catalog was built from $have but Convert-PowerStigData.ps1 now defaults to $want.")
            $checks++
        }
        if ($StigDir) {
            $mine = Get-FileRelease $have
            if (-not $mine) { $notes.Add("CHECK  $p`: cannot read a version from the file name $have."); $checks++ }
            else {
                $newest = $mine
                foreach ($f in @(Get-ChildItem -LiteralPath $StigDir -File -Filter "$($mine.Prefix)-*.xml" -ErrorAction SilentlyContinue)) {
                    $r = Get-FileRelease $f.Name
                    if ($r -and $r.Prefix -eq $mine.Prefix -and ($r.V -gt $newest.V -or ($r.V -eq $newest.V -and $r.R -gt $newest.R))) { $newest = $r }
                }
                if ($newest.V -ne $mine.V -or $newest.R -ne $mine.R) {
                    $notes.Add("CHECK  $p`: V$($newest.V)R$($newest.R) is in $StigDir, the catalog has $rel. Re-run Convert-PowerStigData.ps1.")
                    $checks++
                    $line += "   -> V$($newest.V)R$($newest.R) available"
                }
            }
        }
        $line
    }
    if (-not $StigDir) { '  (no -StigDir: only the catalog and the converter were compared, not what DISA published.)' }
}

# ---------------------------------------------------------------- CIS
''
$cisPath = Join-Path $Root 'data\cis-map.json'
$cis = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($cisPath))
'CIS benchmarks the rule numbers come from:'
$roleOf = @{ win11 = 'Windows-11-CIS'; win10 = 'Windows-10-CIS'; srv2022 = 'Windows-2022-CIS'; srv2019 = 'Windows-2019-CIS'; srv2016 = 'Windows-2016-CIS' }
foreach ($b in @($cis.benchmarks.PSObject.Properties.Name)) {
    $have = "$($cis.benchmarks.$b)"
    $line = "  {0,-8} {1}" -f $b, $have
    if ($CisDir -and $roleOf[$b]) {
        $readme = Join-Path (Join-Path $CisDir $roleOf[$b]) 'README.md'
        if (Test-Path -LiteralPath $readme) {
            # The roles name their benchmark in the README ("CIS ... Benchmark v3.0.0").
            $found = @([regex]::Matches([System.IO.File]::ReadAllText($readme), '(?i)benchmark\s+v?(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
            $mineV = if ($have -match 'v(\d+\.\d+\.\d+)') { $Matches[1] } else { '' }
            if ($found.Count -gt 0 -and $mineV -and $found -notcontains $mineV) {
                $notes.Add("CHECK  $b`: $($roleOf[$b]) names benchmark v$($found -join ', v'), the mapping says v$mineV. Re-run Convert-CisMapping.ps1.")
                $checks++
                $line += "   -> v$($found -join ', v') in the clone"
            }
            elseif ($found.Count -eq 0) { $line += '   (the clone does not name its benchmark version)' }
        }
        else { $line += "   (no $($roleOf[$b])\README.md in -CisDir)" }
    }
    $line
}
if (-not $CisDir) { '  (no -CisDir: the clones were not read.)' }

# ---------------------------------------------------------------- by hand
''
. (Join-Path $Root 'lib\Checks.ps1')
$acn = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path $Root 'data\acn-nis2-measures.json')))
'Published as documents, nothing local to compare (check by hand at a release):'
"  Essential Eight   ASD Essential Eight Maturity Model, $($script:E8ModelVersion) (lib\Checks.ps1, `$script:E8ModelVersion)"
"  NIS2 / ACN        $("$($acn.source)" -replace '\s+', ' ')"

''
if ($checks -eq 0) { 'UP TO DATE: nothing newer found in what was given.' }
else {
    $notes | ForEach-Object { $_ }
    "$checks thing(s) to look at."
}
