param(
  # Folders that contain your service/root schemas
  [Parameter(Mandatory=$true)][string[]] $Roots,
  # Path to common.xsd
  [Parameter(Mandatory=$true)][string]   $CommonPath,
  # Namespace of common.xsd
  [string] $CommonNs = 'http://arvest.com/Encore/Common',
  # If you want to only process a subset of type names, list them here (optional)
  [string[]] $OnlyTypes = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- constants / helpers ----------
$XSD_NS = 'http://www.w3.org/2001/XMLSchema'
function Add-Ns([System.Xml.XmlNamespaceManager]$nsm) {
  if (-not $nsm.HasNamespace('xsd')) { $nsm.AddNamespace('xsd', $XSD_NS) }
}

function Load-Xml([string]$path) {
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $doc.Load($path)
  $doc
}

function Ensure-Common-Headers([System.Xml.XmlDocument]$doc) {
  $schema = $doc.DocumentElement
  if (-not $schema -or $schema.LocalName -ne 'schema' -or $schema.NamespaceURI -ne $XSD_NS) {
    throw "Top element of '$CommonPath' is not xsd:schema"
  }
  # required header values
  $schema.SetAttribute('targetNamespace', $CommonNs)
  $schema.SetAttribute('elementFormDefault','qualified')
  $schema.SetAttribute('attributeFormDefault','unqualified')
  if (-not $schema.HasAttribute('xmlns:c'))   { $schema.SetAttribute('xmlns:c',   $CommonNs) }
  if (-not $schema.HasAttribute('xmlns:xsd')) { $schema.SetAttribute('xmlns:xsd', $XSD_NS)  }
}

function Ensure-Import([System.Xml.XmlDocument]$doc, [string]$schemaLocation, [string]$ns) {
  $nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  Add-Ns $nsm
  $schema = $doc.DocumentElement
  # already imported to the same namespace?
  $existing = $schema.SelectSingleNode(("xsd:import[@namespace='{0}']" -f $ns), $nsm)
  if ($existing) {
    # keep existing schemalocation if present; do nothing
    return $false
  }
  $imp = $doc.CreateElement('xsd','import', $XSD_NS)
  $imp.SetAttribute('namespace', $ns)
  # relative path up one then into Common/common.xsd works for both Service and Root siblings
  $imp.SetAttribute('schemaLocation', $schemaLocation)
  # insert right after the <xsd:schema> start (before type defs)
  $null = $schema.PrependChild($imp)
  return $true
}

function Get-TypeNode([System.Xml.XmlDocument]$doc, [string]$name) {
  $nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  Add-Ns $nsm
  $schema = $doc.DocumentElement
  $node = $schema.SelectSingleNode(("xsd:complexType[@name='{0}']" -f $name), $nsm)
  if (-not $node) { $node = $schema.SelectSingleNode(("xsd:simpleType[@name='{0}']" -f $name), $nsm) }
  $node
}

function Score-TypeNode([System.Xml.XmlNode]$node) {
  if (-not $node) { return 0 }
  $nsm = New-Object System.Xml.XmlNamespaceManager($node.OwnerDocument.NameTable)
  Add-Ns $nsm
  $els = $node.SelectNodes('.//xsd:element', $nsm).Count
  $atts = $node.SelectNodes('.//xsd:attribute', $nsm).Count
  $len = ($node.OuterXml.Length)
  return (1000 * $els + 200 * $atts + $len)
}

function Normalize-TypeXml([System.Xml.XmlNode]$node) {
  if (-not $node) { return '' }
  # drop volatile @id attributes and trim whitespace for comparisons
  $clone = $node.Clone()
  foreach ($attrNode in @($clone.SelectNodes(".//@id"))) { $null = $attrNode.OwnerElement.RemoveAttributeNode($attrNode) }
  return ($clone.OuterXml -replace '\s+', ' ').Trim()
}

function Fix-Local-TypeReferences([System.Xml.XmlDocument]$doc, [string[]]$localTypeNames) {
  $nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  Add-Ns $nsm
  $schema = $doc.DocumentElement

  # ensure c: prefix is bound (quietly add if absent)
  if (-not $schema.HasAttribute('xmlns:c')) { $schema.SetAttribute('xmlns:c', $CommonNs) }

  # upgrade @type / @base that refer to known common types without prefix
  $nodes = $schema.SelectNodes(".//*[@type] | .//*[@base]", $nsm)
  foreach ($n in $nodes) {
    foreach ($attName in @('type','base')) {
      if ($n.Attributes[$attName]) {
        $val = $n.Attributes[$attName].Value
        if ($val -notmatch ':' -and $localTypeNames -contains $val) {
          $n.Attributes[$attName].Value = "c:$val"
        }
        if ($val -in @('string','boolean','decimal','float','double','duration','dateTime','time','date','gYear','gYearMonth','gMonth','gMonthDay','hexBinary','base64Binary','anyURI','QName','NOTATION','normalizedString','token','language','Name','NCName','ID','IDREF','IDREFS','ENTITY','ENTITIES','integer','nonPositiveInteger','negativeInteger','long','int','short','byte','nonNegativeInteger','unsignedLong','unsignedInt','unsignedShort','unsignedByte','positiveInteger')) {
          $n.Attributes[$attName].Value = "xsd:$val"
        }
      }
    }
  }
}

function Remove-Local-Definition([System.Xml.XmlDocument]$doc, [string]$typeName) {
  $node = Get-TypeNode $doc $typeName
  if ($node) { $null = $node.ParentNode.RemoveChild($node); return $true }
  return $false
}

# ---------- 1) Load/prepare common ----------
$CommonPath = (Resolve-Path $CommonPath).Path
$commonDoc  = Load-Xml $CommonPath
Ensure-Common-Headers $commonDoc
$commonRoot = $commonDoc.DocumentElement
$commonNsMgr = New-Object System.Xml.XmlNamespaceManager($commonDoc.NameTable)
Add-Ns $commonNsMgr

# quick set of types already in common
$existingCommonNames =
  @($commonRoot.SelectNodes('/xsd:schema/xsd:complexType[@name]', $commonNsMgr)) +
  @($commonRoot.SelectNodes('/xsd:schema/xsd:simpleType[@name]',  $commonNsMgr)) |
  ForEach-Object { $_.GetAttribute('name') }

$existingCommon = @{}
foreach ($n in $existingCommonNames) { $existingCommon[$n] = $true }

# ---------- 2) Scan all service/root files ----------
$files = foreach ($r in $Roots) { Get-ChildItem -Path $r -Filter *.xsd -Recurse -File }
if (-not $files) { Write-Host "No XSDs found under Roots." -ForegroundColor Yellow; exit 0 }

# map: name -> list of occurrences { File, Doc, Node, Kind, Score, XmlNorm }
$occ = @{}
foreach ($f in $files) {
  $doc = Load-Xml $f.FullName
  $nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  Add-Ns $nsm
  $schema = $doc.DocumentElement
  if (-not $schema -or $schema.LocalName -ne 'schema' -or $schema.NamespaceURI -ne $XSD_NS) { continue }

  $types =
    @($schema.SelectNodes('xsd:complexType[@name]', $nsm)) +
    @($schema.SelectNodes('xsd:simpleType[@name]',  $nsm))

  foreach ($t in $types) {
    $name = $t.GetAttribute('name')
    if ($OnlyTypes.Count -gt 0 -and $OnlyTypes -notcontains $name) { continue }
    if (-not $occ.ContainsKey($name)) { $occ[$name] = @() }
    $kind = if ($t.LocalName -eq 'complexType') { 'complexType' } else { 'simpleType' }
    $score = Score-TypeNode $t
    $xml   = Normalize-TypeXml $t
    $occ[$name] += [pscustomobject]@{
      Name    = $name
      File    = $f.FullName
      Doc     = $doc
      Node    = $t
      Kind    = $kind
      Score   = $score
      Xml     = $xml
      IsSvc   = ($f.FullName -match '\\Service\\')
      IsRoot  = ($f.FullName -match '\\Root\\')
    }
  }
}

# ---------- 3) Pick canonicals & promote to common; remove locals elsewhere ----------
$addedToCommon = 0
$removedLocals = 0
$importsAdded  = 0

foreach ($name in $occ.Keys | Sort-Object) {
  $list = $occ[$name]

  # only interested in “shared” definitions (appears in >= 2 files) OR explicitly requested
  if ($OnlyTypes.Count -eq 0 -and $list.Count -lt 2 -and -not $existingCommon.ContainsKey($name)) { continue }

  # group by normalized XML — if multiple distinct shapes exist, skip and report
  $shapes = $list | Group-Object Xml
  if ($shapes.Count -gt 1) {
    Write-Host "CONFLICT: '$name' has $($shapes.Count) different definitions; resolve before promoting." -ForegroundColor Red
    continue
  }

  # choose canonical by highest score; tie-breakers: Service over Root, then shorter path, then alpha
  $chosen = $list |
    Sort-Object @{e='Score';Descending=$true},
                @{e={ if ($_.IsSvc) {1} elseif ($_.IsRoot){0}else{-1} };Descending=$true},
                @{e={ $_.File.Length };Descending=$false},
                @{e='File';Descending=$false} |
    Select-Object -First 1

  # ensure definition in common
  if (-not $existingCommon.ContainsKey($name)) {
    $tmpXml = "<xsd:$($chosen.Kind) xmlns:xsd='$XSD_NS'>$($chosen.Node.InnerXml)</xsd:$($chosen.Kind)>"
    [xml]$tmpDoc = New-Object System.Xml.XmlDocument
    $tmpDoc.LoadXml($tmpXml)
    $tmpDoc.DocumentElement.SetAttribute('name', $name)
    $imported = $commonDoc.ImportNode($tmpDoc.DocumentElement, $true)
    $null = $commonRoot.AppendChild($imported)
    $existingCommon[$name] = $true
    $addedToCommon++
    Write-Host ("Added {0} to common from: {1}" -f $name, $chosen.File) -ForegroundColor Green
  }

  # remove locals from OTHER files, add import, and prefix references
  foreach ($occItem in $list) {
    $doc  = $occItem.Doc
    $file = $occItem.File
    if ($file -ne $chosen.File) {
      if (Remove-Local-Definition $doc $name) { $removedLocals++ }
      # ensure common import and fix refs
      if (Ensure-Import $doc '..\Common\common.xsd' $CommonNs) { $importsAdded++ }
      Fix-Local-TypeReferences $doc ([string[]]$existingCommon.Keys)
      $doc.Save($file)
    }
  }
}

# also run the prefix fixer across the chosen file itself (just in case) and save all touched docs
$allTouched = ($occ.Values | ForEach-Object { $_ } | Select-Object -ExpandProperty Doc -Unique)
foreach ($d in $allTouched) {
  Fix-Local-TypeReferences $d ([string[]]$existingCommon.Keys)
  $d.Save($d.BaseURI -replace '^file:///', '')
}

# save common last
$commonDoc.Save($CommonPath)

Write-Host ""
Write-Host ("Done. Added to common: {0}, removed local copies: {1}, imports inserted: {2}" -f $addedToCommon, $removedLocals, $importsAdded) -ForegroundColor Cyan
