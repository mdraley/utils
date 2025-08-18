param(
  [Parameter(Mandatory=$true)]  [string[]] $Roots,          # folders to scan (service + root)
  [Parameter(Mandatory=$true)]  [string]   $CommonNs,       # http://arvest.com/Encore/Common
  [Parameter(Mandatory=$true)]  [string]   $CommonPath,     # full path to common-types.xsd
  [Parameter(Mandatory=$false)] [switch]   $FixCommonAlso   # also fix the common XSD itself
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- helpers ---------------------------------------------------------------
function Get-RelativePath {
  param([string]$FromFile, [string]$ToFile)
  $fromDir = Split-Path -Parent (Resolve-Path $FromFile)
  $toFull  = (Resolve-Path $ToFile)
  $uriFrom = [Uri]($fromDir + '\')
  $uriTo   = [Uri]$toFull
  ($uriFrom.MakeRelativeUri($uriTo).ToString()) -replace '/', '\'
}

$XSD_NS = 'http://www.w3.org/2001/XMLSchema'
$BUILTINS = @('string','boolean','decimal','float','double','duration','dateTime','time','date',
  'gYearMonth','gYear','gMonthDay','gDay','gMonth','hexBinary','base64Binary','anyURI','QName',
  'NOTATION','normalizedString','token','language','Name','NCName','ID','IDREF','IDREFS','ENTITY',
  'ENTITIES','NMTOKEN','NMTOKENS','byte','int','integer','long','short','unsignedByte','unsignedInt',
  'unsignedLong','unsignedShort','nonNegativeInteger','positiveInteger','nonPositiveInteger','negativeInteger')

# Load the set of type names defined in common (complex+simple)
[xml]$commonDoc = New-Object System.Xml.XmlDocument
$commonDoc.PreserveWhitespace = $true
$commonDoc.Load($CommonPath)
$nsmCommon = New-Object System.Xml.XmlNamespaceManager($commonDoc.NameTable)
$nsmCommon.AddNamespace('xsd',$XSD_NS)
$COMMON_TYPE_NAMES =
  @($commonDoc.SelectNodes('/xsd:schema/xsd:complexType[@name]', $nsmCommon) | ForEach-Object {$_.GetAttribute('name')}) +
  @($commonDoc.SelectNodes('/xsd:schema/xsd:simpleType[@name]' , $nsmCommon) | ForEach-Object {$_.GetAttribute('name')})
$COMMON_TYPE_NAMES = $COMMON_TYPE_NAMES | Sort-Object -Unique

# Build file list
$files = foreach ($r in $Roots) { Get-ChildItem -Path $r -Filter *.xsd -Recurse -File }
if ($FixCommonAlso) { $files += Get-Item $CommonPath }
$files = $files | Sort-Object FullName -Unique
if (-not $files) { Write-Host "No XSDs found under Roots." -ForegroundColor Yellow; return }

$updated = 0
foreach ($f in $files) {
  [xml]$doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  try { $doc.Load($f.FullName) } catch { Write-Host "Bad XML: $($f.FullName)" -ForegroundColor Red; continue }
  if (-not $doc.DocumentElement) { continue }

  $nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  $nsm.AddNamespace('xsd',$XSD_NS)
  $schema = $doc.DocumentElement
  if ($schema.LocalName -ne 'schema' -or $schema.NamespaceURI -ne $XSD_NS) { continue }

  # Ensure c: and tns: prefixes exist
  if (-not $schema.HasAttribute('xmlns:c'))  { $schema.SetAttribute('xmlns:c', $CommonNs) | Out-Null }
  $tnsUri = $schema.GetAttribute('targetNamespace')
  if ($tnsUri) {
    # add tns only if missing; harmless to add alongside any existing prefixes for same URI
    if (-not ($schema.Attributes | Where-Object { $_.Name -eq 'xmlns:tns' })) {
      $schema.SetAttribute('xmlns:tns', $tnsUri) | Out-Null
    }
  }

  # Collect local type names (complex+simple) to prefix as tns:
  $LOCAL_TYPE_NAMES =
    @($schema.SelectNodes('xsd:complexType[@name]', $nsm) | ForEach-Object {$_.GetAttribute('name')}) +
    @($schema.SelectNodes('xsd:simpleType[@name]' , $nsm) | ForEach-Object {$_.GetAttribute('name')})
  $LOCAL_TYPE_NAMES = $LOCAL_TYPE_NAMES | Sort-Object -Unique

  $madeCommonRef = $false
  $changed = $false

  # Fix @type and @base everywhere in the document
  foreach ($attrName in @('type','base')) {
    $attrs = $doc.SelectNodes("//@${attrName}", $nsm)
    foreach ($a in $attrs) {
      $v = $a.Value
      if (-not $v) { continue }
      if ($v -match '^[^:]+:') { continue } # already prefixed, leave as-is

      if ($BUILTINS -contains $v) {
        $a.Value = "xsd:$v"
        $changed = $true
        continue
      }
      if ($COMMON_TYPE_NAMES -contains $v) {
        $a.Value = "c:$v"
        $changed = $true
        $madeCommonRef = $true
        continue
      }
      if ($LOCAL_TYPE_NAMES -contains $v) {
        if ($tnsUri) {
          $a.Value = "tns:$v"
          $changed = $true
          continue
        }
      }
      # else: unknown external type — leave it alone (assumes another import handles it)
    }
  }

  # If we introduced any c: references, ensure an xsd:import is present with correct schemaLocation
  if ($madeCommonRef) {
    $imports = $schema.SelectNodes("xsd:import[@namespace='$CommonNs']", $nsm)
    $rel = Get-RelativePath -FromFile $f.FullName -ToFile $CommonPath
    if (-not $imports -or $imports.Count -eq 0) {
      $imp = $doc.CreateElement('xsd','import',$XSD_NS)
      $imp.SetAttribute('namespace', $CommonNs)
      $imp.SetAttribute('schemaLocation', $rel)
      [void]$schema.PrependChild($imp)
      $changed = $true
    } else {
      $curr = $imports.Item(0).GetAttribute('schemaLocation')
      if ($curr -ne $rel -and $rel) {
        $imports.Item(0).SetAttribute('schemaLocation', $rel)
        $changed = $true
      }
    }
  }

  if ($changed) {
    $doc.Save($f.FullName)
    $updated++
    if ($updated % 20 -eq 0) { Write-Host "Updated $updated files..." -ForegroundColor Cyan }
  }
}

Write-Host "Done. Updated $updated file(s)." -ForegroundColor Green
