param(
  # Path to your common schema
  [Parameter(Mandatory=$true)][string]$Common = "C:\code\encore\schema\Common\common.xsd",
  # Your common namespace URI
  [string]$CommonNs = "http://arvest.com/Encore/Common"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- helpers ----------
$XSD_NS = "http://www.w3.org/2001/XMLSchema"
$BUILTINS = @(
  'anySimpleType','string','boolean','decimal','float','double','duration',
  'dateTime','time','date','gYearMonth','gYear','gMonthDay','gDay','gMonth',
  'hexBinary','base64Binary','anyURI','QName','NOTATION',
  'normalizedString','token','language','Name','NCName','ID','IDREF','IDREFS',
  'ENTITY','ENTITIES','integer','nonPositiveInteger','negativeInteger',
  'long','int','short','byte','nonNegativeInteger','unsignedLong',
  'unsignedInt','unsignedShort','unsignedByte','positiveInteger'
) | ForEach-Object { "xsd:$_" }

function Add-PrefixIfNeeded {
  param([string]$raw)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $raw }

  # already a QName?
  if ($raw -match '^\w+:\w+$') { return $raw }

  # xsd built-ins (no prefix yet -> give xsd:)
  if ($BUILTINS -contains ("xsd:$raw")) { return "xsd:$raw" }

  # otherwise assume it's a local/common type => c:
  return "c:$raw"
}

# ---------- load ----------
[xml]$doc = New-Object System.Xml.XmlDocument
$doc.PreserveWhitespace = $true
$doc.Load($Common)

$schema = $doc.DocumentElement
if (-not $schema -or $schema.LocalName -ne 'schema' -or $schema.NamespaceURI -ne $XSD_NS) {
  throw "Top element is not xsd:schema in $Common"
}

# NS manager
$nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$nsm.AddNamespace('xsd', $XSD_NS)

# ---------- normalize header ----------
$schema.SetAttribute('targetNamespace', $CommonNs) | Out-Null
$schema.SetAttribute('elementFormDefault', 'qualified')   | Out-Null
$schema.SetAttribute('attributeFormDefault', 'unqualified') | Out-Null
if (-not $schema.HasAttribute('xmlns:c'))   { $schema.SetAttribute('xmlns:c',   $CommonNs)   | Out-Null }
if (-not $schema.HasAttribute('xmlns:tns')) { $schema.SetAttribute('xmlns:tns', $CommonNs)   | Out-Null }
if (-not $schema.HasAttribute('xmlns:xsd')) { $schema.SetAttribute('xmlns:xsd', $XSD_NS)     | Out-Null }

# ---------- remove self-import/include (common importing itself) ----------
$imports = $schema.SelectNodes("//xsd:import[@namespace='$CommonNs']|//xsd:include", $nsm)
$removed = 0
foreach ($imp in @($imports)) {
  # remove only if it points at our common or clearly self-include
  $loc = $imp.GetAttribute('schemaLocation')
  if ($imp.LocalName -eq 'include' -or
      $imp.GetAttribute('namespace') -eq $CommonNs -or
      ($loc -and ($loc -match '(?i)\\common\\common\.xsd$' -or $loc -match '(?i)/common/common\.xsd$'))) {
    $imp.ParentNode.RemoveChild($imp) | Out-Null
    $removed++
  }
}
if ($removed -gt 0) { Write-Host "Removed $removed self-import/include node(s)." -ForegroundColor Yellow }

# ---------- collect local type names (defined in common) ----------
$localNames =
  @($schema.SelectNodes('xsd:complexType[@name]', $nsm)) +
  @($schema.SelectNodes('xsd:simpleType[@name]',  $nsm)) |
  ForEach-Object { $_.GetAttribute('name') } |
  Sort-Object -Unique

# For quick membership test
$localSet = @{}
$localNames | ForEach-Object { $localSet[$_] = $true }

# ---------- rewrite @type and @base everywhere ----------
$changed = 0

# attributes named "type" or "base" under the schema subtree
$attrs = $schema.SelectNodes('.//@type | .//@base', $nsm)
foreach ($a in $attrs) {
  $val = $a.Value
  if ([string]::IsNullOrWhiteSpace($val)) { continue }

  # already qualified?
  if ($val -match '^\w+:\w+$') { continue }

  # choose prefix based on built-ins or local types
  if ($BUILTINS -contains "xsd:$val") {
    $new = "xsd:$val"
  } elseif ($localSet.ContainsKey($val)) {
    $new = "c:$val"
  } else {
    # unknown; still give c: so JAXB sees a QName, and we'll report it below
    $new = "c:$val"
  }

  if ($new -ne $val) {
    $a.Value = $new
    $changed++
  }
}
Write-Host "Prefixed $changed @type/@base attribute(s)." -ForegroundColor Cyan

# ---------- find unresolved references (still not defined here or built-in) ----------
$unresolved = @()

$allRefs = $schema.SelectNodes('.//@type | .//@base', $nsm) | ForEach-Object { $_.Value } | Sort-Object -Unique
foreach ($qname in $allRefs) {
  if ($qname -match '^xsd:') { continue }
  if ($qname -match '^(c|tns):(.+)$') {
    $name = $Matches[2]
    if (-not $localSet.ContainsKey($name)) {
      $unresolved += $name
    }
  }
}
$unresolved = $unresolved | Sort-Object -Unique

# ---------- save ----------
$doc.Save($Common)
Write-Host "Saved: $Common" -ForegroundColor Green

# ---------- report ----------
if ($unresolved.Count -gt 0) {
  Write-Host "`nUnresolved references in common.xsd (add or fix these types):" -ForegroundColor Yellow
  $unresolved | ForEach-Object { "  - $_" } | Write-Output
} else {
  Write-Host "`nNo unresolved references detected in common.xsd." -ForegroundColor Green
}
