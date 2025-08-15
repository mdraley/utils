param(
  [Parameter(Mandatory = $true)]
  [string[]] $Roots,

  [Parameter(Mandatory = $false)]
  [string[]] $TypeNames,

  [Parameter(Mandatory = $false)]
  [string] $TypeNamesCsv,

  [Parameter(Mandatory = $true)]
  [string] $CommonOutDir,

  [Parameter(Mandatory = $true)]
  [string] $CommonNamespace,

  [string] $CommonFileName = "common.xsd",

  [int] $BatchSize = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Resolve type names from CSV if provided ---
if ($TypeNamesCsv -and -not $TypeNames) {
  if (-not (Test-Path $TypeNamesCsv)) {
    throw "CSV file not found: $TypeNamesCsv"
  }
  $TypeNames = Import-Csv $TypeNamesCsv |
    Select-Object -Expand Name |
    ForEach-Object { $_ -replace '\.java$','' } |
    Sort-Object -Unique
  Write-Host "Loaded $($TypeNames.Count) type names from CSV: $TypeNamesCsv" -ForegroundColor Cyan
}

if (-not $TypeNames -or $TypeNames.Count -eq 0) {
  throw "No type names provided. Use -TypeNames or -TypeNamesCsv."
}

# --- Prep output paths ---
if (-not (Test-Path $CommonOutDir)) {
  New-Item -ItemType Directory -Path $CommonOutDir | Out-Null
}
$commonPath  = Join-Path $CommonOutDir $CommonFileName
$detailCsv   = Join-Path $CommonOutDir "extracted_types_detail.csv"
$refsCsv     = Join-Path $CommonOutDir "references_report.csv"
$conflictCsv = Join-Path $CommonOutDir "conflicts_report.csv"

# --- Gather all XSD files from Roots ---
$xsds = foreach ($r in $Roots) {
  if (-not (Test-Path $r)) { throw "Root not found: $r" }
  Get-ChildItem -Path $r -Recurse -File -Filter *.xsd
}
if (-not $xsds -or $xsds.Count -eq 0) {
  throw "No .xsd files found under:`n$($Roots -join "`n")"
}

# --- Helpers ---
function New-CommonSchemaDoc {
  param([string]$TargetNs)
  $xml = @"
<xsd:schema xmlns:xsd="http://www.w3.org/2001/XMLSchema"
            targetNamespace="$TargetNs"
            xmlns:c="$TargetNs"
            elementFormDefault="qualified"
            attributeFormDefault="unqualified">
</xsd:schema>
"@
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $doc.LoadXml($xml)
  return $doc
}

function New-XsdNsMgr {
  param([xml]$Doc)
  $nsmgr = New-Object System.Xml.XmlNamespaceManager($Doc.NameTable)
  $nsmgr.AddNamespace("xsd","http://www.w3.org/2001/XMLSchema")
  return $nsmgr
}

function Get-TargetNamespace {
  param([xml]$Doc)
  $ns = $Doc.DocumentElement.GetAttribute("targetNamespace")
  if ([string]::IsNullOrWhiteSpace($ns)) { "" } else { $ns }
}

# --- Load or create common.xsd once ---
[xml]$commonDoc = New-Object System.Xml.XmlDocument
if (Test-Path $commonPath) {
  $commonDoc.Load($commonPath)
} else {
  $commonDoc = New-CommonSchemaDoc -TargetNs $CommonNamespace
}
$commonRoot   = $commonDoc.DocumentElement
$nsmgrCommon  = New-XsdNsMgr -Doc $commonDoc

# --- Accumulators for reports across batches ---
$details   = New-Object System.Collections.Generic.List[object]
$references= New-Object System.Collections.Generic.List[object]
$conflicts = New-Object System.Collections.Generic.List[object]

# --- Batch the work if requested ---
$allNames = @($TypeNames)           # ensure array
$total    = $allNames.Count
$step     = if ($BatchSize -gt 0) { [int]$BatchSize } else { $total }

for ($i = 0; $i -lt $total; $i += $step) {
  $batch = $allNames[$i..([Math]::Min($i+$step-1, $total-1))]
  Write-Host "Processing types $i..$([Math]::Min($i+$step-1, $total-1))  (count=$($batch.Count))" -ForegroundColor Cyan

  # Per-batch definition map
  $definitions = @{}
  foreach ($t in $batch) { $definitions[$t] = @() }

  # Scan all XSDs for this batch
  foreach ($file in $xsds) {
    [xml]$doc = New-Object System.Xml.XmlDocument
    try { $doc.Load($file.FullName) } catch { continue }
    $nsmgr = New-XsdNsMgr -Doc $doc
    $tns   = Get-TargetNamespace -Doc $doc

    foreach ($t in $batch) {
      # Find complexType definition
      $ctList = $doc.DocumentElement.SelectNodes("xsd:complexType[@name='$t']", $nsmgr)
      $ct     = if ($ctList -and $ctList.Count -gt 0) { $ctList.Item(0) } else { $null }
      if ($ct) {
        $definitions[$t] += @{ Kind="complex"; Xml=$ct.OuterXml; File=$file.FullName; Namespace=$tns }
        $details.Add([pscustomobject]@{ Type=$t; Kind="complexType"; Source=$file.FullName; Namespace=$tns })
      }

      # Find simpleType definition
      $stList = $doc.DocumentElement.SelectNodes("xsd:simpleType[@name='$t']", $nsmgr)
      $st     = if ($stList -and $stList.Count -gt 0) { $stList.Item(0) } else { $null }
      if ($st) {
        $definitions[$t] += @{ Kind="simple"; Xml=$st.OuterXml; File=$file.FullName; Namespace=$tns }
        $details.Add([pscustomobject]@{ Type=$t; Kind="simpleType";  Source=$file.FullName; Namespace=$tns })
      }

      # Find references to the type (qualified or unqualified)
      $refNodes = $doc.SelectNodes("//xsd:element[@type='$t' or contains(@type,':$t')]", $nsmgr)
      foreach ($rn in $refNodes) {
        $references.Add([pscustomobject]@{
          Type      = $t
          Element   = $rn.GetAttribute("name")
          File      = $file.FullName
          Namespace = $tns
        })
      }
    }
  }

  # Write/append definitions for this batch into common.xsd, detecting conflicts
  foreach ($t in $batch) {
    $defs = $definitions[$t]
    if (-not $defs -or $defs.Count -eq 0) {
      Write-Host "WARN: No definition found for type '$t' in scanned XSDs." -ForegroundColor Yellow
      continue
    }

    # Group by exact XML to detect different definitions
    $byXml = $defs | Group-Object { $_.Xml.Trim() }

    if ($byXml.Count -gt 1) {
      foreach ($g in $byXml) {
        $g.Group | ForEach-Object {
          $conflicts.Add([pscustomobject]@{
            Type      = $t
            Kind      = $_.Kind
            Source    = $_.File
            Namespace = $_.Namespace
          })
        }
      }
      Write-Host "CONFLICT: '$t' has $($byXml.Count) different definitions; review $([IO.Path]::GetFileName($conflictCsv))." -ForegroundColor Red
      continue
    }

    # Single canonical definition → ensure not already present, then append
    $chosen   = $byXml[0].Group[0]
    $lookup   = ("xsd:{0}Type[@name='{1}']" -f $chosen.Kind, $t)
    $existingList = $commonRoot.SelectNodes($lookup, $nsmgrCommon)
    $existing     = if ($existingList -and $existingList.Count -gt 0) { $existingList.Item(0) } else { $null }
    if (-not $existing) {
      [xml]$tmp = New-Object System.Xml.XmlDocument
      $tmp.LoadXml($chosen.Xml)
      $imported = $commonDoc.ImportNode($tmp.DocumentElement, $true)
      $commonRoot.AppendChild($imported) | Out-Null
    }
  }

  # Save after each batch so you can inspect incrementally
  $commonDoc.Save($commonPath)
  Write-Host "Saved common schema: $commonPath" -ForegroundColor Green
}

# --- Write reports (overwrite each run for a clean slate) ---
$details    | Export-Csv -Path $detailCsv   -NoTypeInformation -Encoding UTF8
$references | Export-Csv -Path $refsCsv     -NoTypeInformation -Encoding UTF8
if ($conflicts.Count -gt 0) {
  $conflicts | Export-Csv -Path $conflictCsv -NoTypeInformation -Encoding UTF8
}

Write-Host ""
Write-Host "Created/updated: $commonPath" -ForegroundColor Green
Write-Host "Reports:" -ForegroundColor Green
Write-Host "  $detailCsv" -ForegroundColor Green
Write-Host "  $refsCsv"   -ForegroundColor Green
if ($conflicts.Count -gt 0) {
  Write-Host "  $conflictCsv  (resolve these before centralizing)" -ForegroundColor Yellow
}
