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

# Gather .java files, skipping boilerplate that always duplicates by design
$files = Get-ChildItem -Path $ResolvedRoots -Recurse -File -Include *.java -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -notin @('ObjectFactory.java','package-info.java') }

if (-not $files -or $files.Count -eq 0) {
  throw "No *.java files found under:`n$($ResolvedRoots -join "`n")"
}

# Helper: read package from file (first 'package x.y.z;' wins). Returns '' if none found.
function Get-JavaPackage {
  param([string]$FilePath)
  try {
    # Read a small head of the file for speed
    $lines = Get-Content -Path $FilePath -TotalCount 50 -ErrorAction Stop
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

# Build records: Name, Package, FullPath
$records = foreach ($f in $files) {
  [PSCustomObject]@{
    Name     = $f.Name
    Package  = Get-JavaPackage -FilePath $f.FullName
    FullPath = $f.FullName
  }
}

# Group by class name; keep only those present in >1 DISTINCT package
$commonCandidates =
  $records |
  Group-Object Name |
  ForEach-Object {
    $distinctPkgs = ($_.Group | Select-Object -Expand Package | Where-Object { $_ -ne '' } | Sort-Object -Unique)
    if ($distinctPkgs.Count -gt 1) {
      # Return all occurrences for detail view
      $_.Group
    }
  } |
  Where-Object { $_ -ne $null }

# Write detail file: one row per occurrence
$detailCsv = Join-Path $ResolvedOut 'common_candidates_detail.csv'
$commonCandidates |
  Select-Object Name, Package, FullPath |
  Export-Csv -Path $detailCsv -NoTypeInformation -Encoding UTF8

# Write summary file: one row per class with count + package list
$summaryCsv = Join-Path $ResolvedOut 'common_candidates_by_name.csv'
$records |
  Group-Object Name |
  ForEach-Object {
    $pkgs = ($_.Group | Select-Object -Expand Package | Where-Object { $_ -ne '' } | Sort-Object -Unique)
    if ($pkgs.Count -gt 1) {
      [PSCustomObject]@{
        Name        = $_.Name
        PackageCount= $pkgs.Count
        Packages    = ($pkgs -join ';')
        FileCount   = $_.Count
      }
    }
  } |
  Sort-Object -Property PackageCount, Name -Descending |
  Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8

Write-Host "Wrote:" -ForegroundColor Green
Write-Host "  $detailCsv"
Write-Host "  $summaryCsv"
