param(
  [Parameter(Mandatory=$true)]
  [string]$OutDir,

  [Parameter(Mandatory=$true)]
  [string]$RawMergedFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemaDir = (Resolve-Path $OutDir).Path
$archiveDir = Join-Path $schemaDir '_archive'
New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

$commonPath  = Join-Path $schemaDir 'hostcomm-common.xsd'
$wrapperPath = Join-Path $schemaDir 'hostcomm-common-wrapper.xsd'

# archive copy
$rawName = [IO.Path]::GetFileName($RawMergedFile)
$rawBak = Join-Path $archiveDir ("{0}.{1:yyyyMMddHHmmss}.bak" -f $rawName,(Get-Date))
Copy-Item $RawMergedFile $rawBak
Write-Host "Archived copy -> $rawBak"

[xml]$doc = Get-Content $RawMergedFile -Raw
$nsUri = $doc.DocumentElement.NamespaceURI
if (-not $nsUri) { $nsUri = "http://www.w3.org/2001/XMLSchema" }

$new = New-Object System.Xml.XmlDocument
$new.AppendChild($new.CreateXmlDeclaration('1.0','UTF-8',$null)) | Out-Null
$xsSchema = $new.CreateElement('xs','schema',$nsUri)
$xsSchema.SetAttribute('elementFormDefault','qualified')
$xsSchema.SetAttribute('attributeFormDefault','unqualified')
$xsSchema.SetAttribute('xmlns:xs',$nsUri)
$new.AppendChild($xsSchema) | Out-Null

$kinds = @('complexType','simpleType','element','group','attributeGroup','attribute')
$seen = @{}
foreach ($k in $kinds) { $seen[$k] = New-Object 'System.Collections.Generic.HashSet[string]' }

foreach ($n in $doc.DocumentElement.ChildNodes) {
  if ($n.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
  $kind = $n.LocalName
  if ($kinds -notcontains $kind) { continue }

  $nameAttr = $n.Attributes['name']
  if ($nameAttr) {
    $name = $nameAttr.Value
    if ($seen[$kind].Add($name)) {
      $xsSchema.AppendChild($new.ImportNode($n,$true)) | Out-Null
    }
  } else {
    $xsSchema.AppendChild($new.ImportNode($n,$true)) | Out-Null
  }
}

$new.Save($commonPath)
Write-Host "Wrote canonical -> $commonPath"

@"
<?xml version="1.0" encoding="UTF-8"?>
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
           elementFormDefault="qualified"
           attributeFormDefault="unqualified">
  <xs:include schemaLocation="hostcomm-common.xsd"/>
</xs:schema>
"@ | Set-Content -Path $wrapperPath -Encoding UTF8

Write-Host "Wrote wrapper -> $wrapperPath"
