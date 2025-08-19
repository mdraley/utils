param(
  # Path to your hostcomm-xsd root that contains the two folders:
  #   http_www_fiserv_com_cbs   and   _no_namespace_
  [Parameter(Mandatory=$true)]
  [string]$RootDir,

  # The namespace you want to standardize on for CBS (http OR https; pick one)
  [string]$CbsNamespace = 'http://www.fiserv.com/cbs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-CbsFolder {
  param([string]$dir, [string]$ns)

  if (!(Test-Path $dir)) { throw "CBS folder not found: $dir" }

  Write-Host "== CBS: Normalizing files in $dir to namespace: $ns"

  $files = Get-ChildItem -Path $dir -Filter *.xsd -File
  $changed = 0
  foreach ($f in $files) {
    $text = Get-Content $f.FullName -Raw

    # Ensure targetNamespace present & normalized
    if ($text -notmatch 'targetNamespace="https?://www\.fiserv\.com/cbs"') {
      $text = $text -replace '<xs:schema', "<xs:schema targetNamespace=""$ns"""
    } else {
      $text = $text -replace 'targetNamespace="https?://www\.fiserv\.com/cbs"', "targetNamespace=""$ns"""
    }

    # Ensure xmlns:tns present & normalized
    if ($text -notmatch 'xmlns:tns="https?://www\.fiserv\.com/cbs"') {
      $text = $text -replace '<xs:schema', "<xs:schema xmlns:tns=""$ns"""
    } else {
      $text = $text -replace 'xmlns:tns="https?://www\.fiserv\.com/cbs"', "xmlns:tns=""$ns"""
    }

    # Replace any qN: prefixes with tns:
    $text2 = $text -replace 'q\d+:', 'tns:'

    if ($text2 -ne $text) { $changed++ }
    Set-Content -Path $f.FullName -Value $text2 -Encoding UTF8
  }

  # Fix CBS wrapper header if present
  $wrapper = Join-Path $dir 'http_www_fiserv_com_cbs.xsd'
  if (Test-Path $wrapper) {
    $w = Get-Content $wrapper -Raw
    # Ensure namespace + prefix exist and match desired value
    if ($w -notmatch 'targetNamespace="https?://www\.fiserv\.com/cbs"') {
      $w = $w -replace '<xs:schema', "<xs:schema targetNamespace=""$ns"""
    } else {
      $w = $w -replace 'targetNamespace="https?://www\.fiserv\.com/cbs"', "targetNamespace=""$ns"""
    }
    if ($w -notmatch 'xmlns:tns="https?://www\.fiserv\.com/cbs"') {
      $w = $w -replace '<xs:schema', "<xs:schema xmlns:tns=""$ns"""
    } else {
      $w = $w -replace 'xmlns:tns="https?://www\.fiserv\.com/cbs"', "xmlns:tns=""$ns"""
    }
    Set-Content -Path $wrapper -Value $w -Encoding UTF8
  }

  Write-Host ("   Updated {0} file(s) with prefix/namespace normalization." -f $changed)
}

function Merge-NoNamespace {
  param([string]$dir)

  if (!(Test-Path $dir)) { throw "_no_namespace_ folder not found: $dir" }

  Write-Host "== No-namespace: de-duplicating globals in $dir"

  $wrapperName = '_no_namespace_.xsd'
  $wrapperPath = Join-Path $dir $wrapperName

  # move originals aside (we will create a merged xsd)
  $dupsDir = Join-Path $dir '_dups'
  New-Item -ItemType Directory -Force -Path $dupsDir | Out-Null

  # Load or create the merged document
  $mergedName = '_no_namespace_.merged.xsd'
  $mergedPath = Join-Path $dir $mergedName

  $merged = New-Object System.Xml.XmlDocument
  $mergedPreserve = $true
  $merged.AppendChild($merged.CreateXmlDeclaration('1.0','UTF-8',$null)) | Out-Null
  $schema = $merged.CreateElement('xs','schema','http://www.w3.org/2001/XMLSchema')
  $schema.SetAttribute('elementFormDefault','qualified')
  $schema.SetAttribute('attributeFormDefault','unqualified')
  $merged.AppendChild($schema) | Out-Null

  # Track seen names per component kind to avoid duplicates
  $seen = @{
    'complexType'     = New-Object 'System.Collections.Generic.HashSet[string]'
    'simpleType'      = New-Object 'System.Collections.Generic.HashSet[string]'
    'element'         = New-Object 'System.Collections.Generic.HashSet[string]'
    'attributeGroup'  = New-Object 'System.Collections.Generic.HashSet[string]'
    'group'           = New-Object 'System.Collections.Generic.HashSet[string]'
  }

  $partFiles = Get-ChildItem -Path $dir -Filter *.xsd -File | Where-Object { $_.Name -ne $wrapperName }
  $added = 0; $skipped = 0

  foreach ($pf in $partFiles) {
    # NOTE: many of these generated files don’t have a namespace; good.
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($pf.FullName)

    $nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $nsm.AddNamespace('xs','http://www.w3.org/2001/XMLSchema')

    # Validate: ensure no targetNamespace in these parts
    $tn = $doc.DocumentElement.GetAttribute('targetNamespace')
    if ($tn) {
      Write-Warning ("{0} declares a targetNamespace ('{1}'). Removing it for no-namespace group." -f $pf.Name,$tn)
      $doc.DocumentElement.RemoveAttribute('targetNamespace')
    }

    $nodes = $doc.SelectNodes('/xs:schema/*', $nsm)
    foreach ($node in $nodes) {
      if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
      $local = $node.LocalName

      if ($local -in $seen.Keys) {
        $name = $node.Attributes['name']?.Value
        if ([string]::IsNullOrWhiteSpace($name)) {
          # anonymous/inline component – just copy
          $imported = $merged.ImportNode($node, $true)
          $schema.AppendChild($imported) | Out-Null
          $added++
        } else {
          if ($seen[$local].Add($name)) {
            $imported = $merged.ImportNode($node, $true)
            $schema.AppendChild($imported) | Out-Null
            $added++
          } else {
            $skipped++
          }
        }
      } else {
        # other nodes (annotations, etc) – copy once
        $imported = $merged.ImportNode($node, $true)
        $schema.AppendChild($imported) | Out-Null
        $added++
      }
    }

    # park the processed file; merged will be used instead
    Move-Item -Path $pf.FullName -Destination $dupsDir -Force
  }

  $merged.Save($mergedPath)

  # Rebuild wrapper to include only the merged file
  $wrapperXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
           elementFormDefault="qualified"
           attributeFormDefault="unqualified">
  <xs:include schemaLocation="$mergedName"/>
</xs:schema>
"@
  Set-Content -Path $wrapperPath -Value $wrapperXml -Encoding UTF8

  Write-Host ("   Merged {0} component(s); skipped {1} duplicate(s)." -f $added, $skipped)
  Write-Host ("   Wrapper now includes: {0}" -f $mergedName)
  Write-Host ("   Original parts were moved to: {0}" -f $dupsDir)
}

# ---------- RUN ----------
$CBS = Join-Path $RootDir 'http_www_fiserv_com_cbs'
$NON = Join-Path $RootDir '_no_namespace_'

Normalize-CbsFolder -dir $CBS -ns $CbsNamespace
Merge-NoNamespace   -dir $NON

Write-Host "`nDone. Now run:  mvn clean generate-sources"
