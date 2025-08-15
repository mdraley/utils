<#  wire-to-common.ps1
    Automate wiring XSDs to shared common.xsd after extraction.

    What it does (for all rows in references_report.csv):
      1) Adds xmlns:c="http://bank/common" to <xsd:schema> if missing
      2) Adds <xsd:import namespace="http://bank/common" schemaLocation="RELATIVE/PATH/common.xsd"> if missing
      3) Rewrites @type="FooType" or "ns:FooType" → @type="c:FooType" for all moved types
      4) Removes local <xsd:complexType name="FooType"> / <xsd:simpleType name="FooType"> if present
      5) Backs up each file as *.bak once, and is idempotent

    Inputs:
      -RefsCsv       : Common\references_report.csv produced by extract-common-types.ps1
      -TypesCsv      : (optional) CSV with a Name column (StatusType.java) to limit scope to a batch
      -Roots         : folders to search for XSDs (Service Level + Root Level)
      -CommonNs      : http://bank/common
      -CommonPath    : full path to Common\common.xsd (used to compute schemaLocation)

    Usage:
      cd C:\code\encore\schema\Common
      .\wire-to-common.ps1 `
        -RefsCsv "$PWD\references_report.csv" `
        -Roots "C:\code\encore\schema\Service Level","C:\code\encore\schema\Root Level" `
        -CommonNs "http://bank/common" `
        -CommonPath "C:\code\encore\schema\Common\common.xsd"
#>

param(
  [Parameter(Mandatory=$true)] [string]   $RefsCsv,
  [Parameter(Mandatory=$false)] [string]  $TypesCsv,
  [Parameter(Mandatory=$true)] [string[]] $Roots,
  [Parameter(Mandatory=$true)] [string]   $CommonNs,
  [Parameter(Mandatory=$true)] [string]   $CommonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RefsCsv))   { throw "RefsCsv not found: $RefsCsv" }
if (-not (Test-Path $CommonPath)){ throw "CommonPath not found: $CommonPath" }

# ---------------------------
# Load list of types to wire
# ---------------------------
$allRefs = Import-Csv $RefsCsv
if ($TypesCsv) {
  if (-not (Test-Path $TypesCsv)) { throw "TypesCsv not found: $TypesCsv" }
  $wanted = Import-Csv $TypesCsv | Select-Object -Expand Name | ForEach-Object { $_ -replace '\.java$','' } | Sort-Object -Unique
  $refs = $allRefs | Where-Object { $wanted -contains $_.Type }
} else {
  $refs = $allRefs
}
$types = $refs.Type | Sort-Object -Unique
if (-not $types) { Write-Host "No types to wire. Exiting." -ForegroundColor Yellow; return }

# Build set of files to touch
$files = $refs.File | Sort-Object -Unique
if (-not $files) { Write-Host "No files to update from refs CSV." -ForegroundColor Yellow; return }

# Quick helper: compute relative schemaLocation
function Get-RelativePath {
  param([string]$FromFile, [string]$ToFile)
  $fromDir = Split-Path -Parent (Resolve-Path $FromFile)
  $toFull  = (Resolve-Path $ToFile)
  $uriFrom = New-Object System.Uri($fromDir + '\')
  $uriTo   = New-Object System.Uri($toFull)
  return $uriFrom.MakeRelativeUri($uriTo).ToString() -replace '/', '\'
}

# Namespace constants
$xsdNs = 'http://www.w3.org/2001/XMLSchema'

# ---------------------------
# Process each XSD file
# ---------------------------
$done = 0
foreach ($path in $files) {
  if (-not (Test-Path $path)) { Write-Host "Skip missing: $path" -ForegroundColor Yellow; continue }

  # Safety: ensure file is within one of the Roots
  $inRoots = $false
  foreach ($r in $Roots) { if ((Resolve-Path $path) -like ((Resolve-Path $r).Path + '*')) { $inRoots = $true; break } }
  if (-not $inRoots) { Write-Host "Skip (outside Roots): $path" -ForegroundColor Yellow; continue }

  # One-time backup
  $bak = "$path.bak"
  if (-not (Test-Path $bak)) { Copy-Item -Path $path -Destination $bak -Force }

  # Load XML
  [xml]$doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  try { $doc.Load($path) } catch { Write-Host "Bad XML: $path" -ForegroundColor Red; continue }
  if (-not $doc.DocumentElement) { continue }

  $nsmgr = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  $nsmgr.AddNamespace('xsd', $xsdNs)

  $schema = $doc.DocumentElement
  if ($schema.LocalName -ne 'schema' -or $schema.NamespaceURI -ne $xsdNs) {
    Write-Host "Not an xsd:schema root: $path" -ForegroundColor Yellow
    continue
  }

  # a) ensure xmlns:c on schema
  $hasC = $false
  foreach ($attr in $schema.Attributes) {
    if ($attr.Name -match '^xmlns:c$' -and $attr.Value -eq $CommonNs) { $hasC = $true; break }
  }
  if (-not $hasC) {
    $schema.SetAttribute('xmlns:c', $CommonNs) | Out-Null
  }

  # b) ensure xsd:import for CommonNs
  $relLoc   = Get-RelativePath -FromFile $path -ToFile $CommonPath
  $importQ  = $schema.SelectNodes("xsd:import[@namespace='$CommonNs']", $nsmgr)
  if (-not $importQ -or $importQ.Count -eq 0) {
    $importNode = $doc.CreateElement('xsd','import',$xsdNs)
    $importNode.SetAttribute('namespace', $CommonNs)
    $importNode.SetAttribute('schemaLocation', $relLoc)
    # Insert import near top (after attributes/namespace decls, before types/elements)
    $null = $schema.PrependChild($importNode)
  } else {
    # Update schemaLocation if different
    $currLoc = $importQ.Item(0).GetAttribute('schemaLocation')
    if ($currLoc -ne $relLoc -and $relLoc) {
      $importQ.Item(0).SetAttribute('schemaLocation', $relLoc)
    }
  }

  # c) remove local type definitions for moved types
  foreach ($tn in $types) {
    $ct = $schema.SelectNodes("xsd:complexType[@name='$tn']", $nsmgr)
    if ($ct -and $ct.Count -gt 0) { $schema.RemoveChild($ct.Item(0)) | Out-Null }
    $st = $schema.SelectNodes("xsd:simpleType[@name='$tn']", $nsmgr)
    if ($st -and $st.Count -gt 0) { $schema.RemoveChild($st.Item(0)) | Out-Null }
  }

  # d) rewrite @type to c:TypeName for moved types (qualified or unqualified)
  #    - @type="FooType" or @type="ns:FooType" -> @type="c:FooType"
  $allElems = $doc.SelectNodes("//xsd:element[@type]", $nsmgr)
  if ($allElems) {
    foreach ($el in $allElems) {
      $tval = $el.GetAttribute('type')
      if (-not $tval) { continue }
      # Extract local type name (strip any prefix)
      $local = ($tval -split ':')[-1]
      if ($types -contains $local) {
        $el.SetAttribute('type', "c:$local")
      }
    }
  }

  # Save changes
  $doc.Save($path)
  $done++
  if ($done % 20 -eq 0) { Write-Host "Updated $done files..." -ForegroundColor Cyan }
}

Write-Host "Finished. Updated $done file(s)." -ForegroundColor Green
