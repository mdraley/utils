# Path to your common schema
$common = "C:\code\encore\encore-api-commons\host-comm-library\host-comm\common-types\src\main\resources\xsd\common.xsd"

# 1) Load XML preserving whitespace
[xml]$doc = New-Object System.Xml.XmlDocument
$doc.PreserveWhitespace = $true
$doc.Load($common)

# 2) Ensure correct header
$schema = $doc.DocumentElement
$XSD_NS = "http://www.w3.org/2001/XMLSchema"
if ($schema.LocalName -ne "schema" -or $schema.NamespaceURI -ne $XSD_NS) {
  throw "Top element is not xsd:schema"
}
$schema.SetAttribute("targetNamespace", "http://arvest.com/Encore/Common")
$schema.SetAttribute("elementFormDefault", "qualified")
$schema.SetAttribute("attributeFormDefault", "unqualified")
# xmlns:xsd is implicit from the element; make sure xmlns:tns exists
if (-not $schema.HasAttribute("xmlns:tns")) {
  $schema.SetAttribute("xmlns:tns", "http://arvest.com/Encore/Common")
}

# Remove self-imports if any
$imports = $schema.SelectNodes("xsd:import[@namespace='http://arvest.com/Encore/Common']", (New-Object System.Xml.XmlNamespaceManager $doc.NameTable).tap({
  $_.AddNamespace("xsd",$XSD_NS)
}))
if ($imports) { $imports | ForEach-Object { $schema.RemoveChild($_) | Out-Null } }

# 3) Collect locally defined type names
$nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$nsm.AddNamespace("xsd",$XSD_NS)
$localTypeNodes = @()
$localTypeNodes += $schema.SelectNodes("xsd:simpleType[@name]", $nsm)
$localTypeNodes += $schema.SelectNodes("xsd:complexType[@name]", $nsm)
$localNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$null = $localTypeNodes | ForEach-Object { $localNames.Add($_.GetAttribute("name")) | Out-Null }

# Helpers
function Is-Builtin([string]$name) {
  $builtins = @(
    'anySimpleType','anyType','string','boolean','decimal','float','double','duration','dateTime','time','date',
    'gYearMonth','gYear','gMonthDay','gDay','gMonth','hexBinary','base64Binary','anyURI','QName','NOTATION',
    'normalizedString','token','language','Name','NCName','ID','IDREF','IDREFS','ENTITY','ENTITIES',
    'integer','nonPositiveInteger','negativeInteger','long','int','short','byte','nonNegativeInteger',
    'unsignedLong','unsignedInt','unsignedShort','unsignedByte','positiveInteger'
  )
  return $builtins -contains $name
}

# 4) Prefix @type and @base
$changed = $false
$attrPaths = @(
  "//xsd:element[@type]",
  "//xsd:attribute[@type]",
  "//xsd:restriction[@base]",
  "//xsd:extension[@base]",
  "//xsd:list[@itemType]",
  "//xsd:union[@memberTypes]"
)

foreach ($path in $attrPaths) {
  $nodes = $schema.SelectNodes($path, $nsm)
  foreach ($node in $nodes) {
    foreach ($attrName in @("type","base","itemType","memberTypes")) {
      if (-not $node.HasAttribute($attrName)) { continue }
      $val = $node.GetAttribute($attrName).Trim()
      if ([string]::IsNullOrEmpty($val)) { continue }

      # Skip already prefixed
      if ($val -match '^[A-Za-z_][\w\.\-]*:') { continue }

      # union memberTypes can be space-separated; handle that case
      $parts = $val -split '\s+'
      $newParts = @()
      $tweaked = $false
      foreach ($p in $parts) {
        if ($p -match '^[A-Za-z_][\w\.\-]*:') { $newParts += $p; continue }
        if (Is-Builtin $p)   { $newParts += "xsd:$p"; $tweaked = $true; continue }
        if ($localNames.Contains($p)) { $newParts += "tns:$p"; $tweaked = $true; continue }
        # leave as-is for now (will be reported)
        $newParts += $p
      }
      if ($tweaked) {
        $node.SetAttribute($attrName, ($newParts -join ' '))
        $changed = $true
      }
    }
  }
}

if ($changed) { $doc.Save($common) }

# 5) Report any remaining unprefixed references (real problems)
$unresolved = @()
foreach ($path in $attrPaths) {
  $schema.SelectNodes($path, $nsm) | ForEach-Object {
    foreach ($a in @("type","base","itemType","memberTypes")) {
      if (-not $_.HasAttribute($a)) { continue }
      ($_.GetAttribute($a) -split '\s+') | Where-Object {
        $_ -and ($_ -notmatch '^[A-Za-z_][\w\.\-]*:') -and -not (Is-Builtin $_) -and -not ($localNames.Contains($_))
      } | ForEach-Object {
        $unresolved += [pscustomobject]@{
          Attribute = $a
          Value     = $_
          Context   = $_.OuterXml
        }
      }
    }
  }
}

if ($unresolved.Count -gt 0) {
  Write-Host ""
  Write-Host "Unresolved references in common.xsd (need definitions or wrong names):" -ForegroundColor Yellow
  $unresolved | Sort-Object Value -Unique | Format-Table -AutoSize
} else {
  Write-Host "common.xsd looks consistent: all references are prefixed and resolvable." -ForegroundColor Green
}
