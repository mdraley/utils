param(
  [Parameter(Mandatory = $true)][string[]] $Roots,
  [Parameter(Mandatory = $true)][string]   $OutDir
)

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve inputs
$ResolvedRoots = foreach ($r in $Roots) {
  if (-not (Test-Path -Path $r)) { throw "Root path not found: $r" }
  (Resolve-Path -Path $r).Path
}

if (-not (Test-Path -Path $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$ResolvedOut = (Resolve-Path -Path $OutDir).Path

# Files (skip boilerplate)
$files = Get-ChildItem -Path $ResolvedRoots -Recurse -File -Include *.java -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -notin @('ObjectFactory.java','package-info.java') }

if (-not $files) { throw "No *.java files found under:`n$($ResolvedRoots -join "`n")" }

function Get-JavaPackage {
  param([string]$FilePath)
  try {
    foreach ($line in (Get-Content -Path $FilePath -TotalCount 80 -ErrorAction Stop)) {
      if ($line -match '^\s*package\s+([a-zA-Z_][\w\.]*)\s*;') { return $Matches[1] }
    }
    return ''
  } catch { return '' }
}

$records = foreach ($f in $files) {
  [pscustomobject]@{
    Name     = $f.Name
    Package  = Get-JavaPackage -FilePath $f.FullName
    FullPath = $f.FullName
  }
}

$groups = $records | Group-Object -Property Name

# Detail
$commonCandidates = foreach ($g in $groups) {
  if (-not $g.Group) { continue }
  $pkgs = $g.Group | Select-Object -Expand Package | Where-Object { $_ -ne '' } | Sort-Object -Unique
  if (@($pkgs).Count -gt 1) { $g.Group }
}

$detailCsv = Join-Path $ResolvedOut 'common_candidates_detail.csv'
$commonCandidates |
  Select-Object Name, Package, FullPath |
  Sort-Object Name, Package, FullPath |
  Export-Csv -Path $detailCsv -NoTypeInformation -Encoding UTF8

# Summary
$summaryCsv = Join-Path $ResolvedOut 'common_candidates_by_name.csv'
$summary = foreach ($g in $groups) {
  if (-not $g.Group) { continue }
  $pkgs = $g.Group | Select-Object -Expand Package | Where-Object { $_ -ne '' } | Sort-Object -Unique
  if (@($pkgs).Count -gt 1) {
    [pscustomobject]@{
      Name         = $g.Name
      PackageCount = @($pkgs).Count
      Packages     = ($pkgs -join ';')
      FileCount    = @($g.Group).Count
    }
  }
}

$summary |
  Sort-Object -Property PackageCount, Name -Descending |
  Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8

Write-Host "Wrote:`n  $detailCsv`n  $summaryCsv" -ForegroundColor Green
