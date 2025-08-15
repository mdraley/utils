param(
  [Parameter(Mandatory = $true)][string[]] $Roots,
  [Parameter(Mandatory = $true)][string]   $OutDir
)

# Session-only policy bypass; no admin required
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Resolve & validate inputs ---
$ResolvedRoots = foreach ($r in $Roots) {
  if (-not (Test-Path -Path $r)) { throw "Root path not found: $r" }
  (Resolve-Path -Path $r).Path
}

if (-not (Test-Path -Path $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$ResolvedOut = (Resolve-Path -Path $OutDir).Path

# --- Gather .java files, skip boilerplate that duplicates by design ---
$files =
  Get-ChildItem -Path $ResolvedRoots -Recurse -File -Include *.java -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -notin @('ObjectFactory.java','package-info.java') }

if (-not $files) {
  throw "No *.java files found under:`n$($ResolvedRoots -join "`n")"
}

# --- Helper: extract package from file (first 'package ...;' line) ---
function Get-JavaPackage {
  param([string]$FilePath)
  try {
    $lines = Get-Content -Path $FilePath -TotalCount 80 -ErrorAction Stop
    foreach ($line in $lines) {
      if ($line -match '^\s*package\s+([a-zA-Z_][\w\.]*)\s*;') {
        return $Matches[1]
      }
    }
    return ''
  } catch {
    return ''
  }
}

# --- Build records: Name, Package, FullPath ---
$records = foreach ($f in $files) {
  [pscustomobject]@{
    Name     = $f.Name
    Package  = Get-JavaPackage -FilePath $f.FullName
    FullPath = $f.FullName
  }
}

# --- Group once and keep the groups (so .Group is always valid) ---
$groups = $records | Group-Object -Property Name

# --- Detail: all occurrences where a class exists in >1 DISTINCT package ---
$commonCandidates = foreach ($g in $groups) {
  if (-not $g.Group) { continue }
  $pkgs = $g.Group |
          Select-Object -ExpandProperty Package |
          Where-Object { $_ -ne '' } |
          Sort-Object -Unique
  if (@($pkgs).Count -gt 1) {
    $g.Group   # return each occurrence for the detail CSV
  }
}

# --- Write detail CSV ---
$detailCsv = Join-Path $ResolvedOut 'common_candidates_detail.csv'
$commonCandidates |
  Select-Object Name, Package, FullPath |
  Sort-Object Name, Package, FullPath |
  Export-Csv -Path $detailCsv -NoTypeInformation -Encoding UTF8

# --- Summary: one row per class with counts + package list ---
$summaryCsv = Join-Path $ResolvedOut 'common_candidates_by_name.csv'
$summary = foreach ($g in $groups) {
  if (-not $g.Group) { continue }
  $pkgs = $g.Group |
          Select-Object -ExpandProperty Package |
          Where-Object { $_ -ne '' } |
          Sort-Object -Unique
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

Write-Host "Wrote:" -ForegroundColor Green
Write-Host "  $detailCsv"
Write-Host "  $summaryCsv"
