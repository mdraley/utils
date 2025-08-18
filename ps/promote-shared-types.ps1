param(
  [Parameter(Mandatory)]
  [string[]]$Roots,                            # e.g. "C:\code\encore\schema\Service","C:\code\encore\schema\Root"

  [Parameter(Mandatory)]
  [string]$CommonPath,                         # e.g. "C:\code\encore\schema\Common\common.xsd"

  [string]$CommonNs = 'http://arvest.com/Encore/Common',

  # optional: process a subset
  [string[]]$OnlyTypes = @(),

  # auto-pick a variant when multiple different definitions exist
  [switch]$AutoPick,

  # where to write conflict log (CSV)
  [string]$LogPath = ".\promote-conflicts.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------- constants / helpers ----------------
$XSD_NS = 'http://www.w3.org/2001/XMLSchema'
$BUILTINS = @(
  'anyType','string','boolean','decimal','float','double','duration','dateTime','time','date',
  'gYearMonth','gYear','gMonthDay','gDay','gMonth','hexBinary','base64Binary','anyURI','QName',
  'NOTATION','normalizedString','token','language','NMTOKEN','NMTOKENS','Name','NCName','ID','IDREF','IDREFS',
  'ENTITY','ENTITIES','integer','nonPositiveInteger','negativeInteger','long','int','short','byte',
  'nonNegativeInteger','unsignedLong','unsignedInt','unsignedShort','unsignedByte','positiveInteger'
)

function Add-NS([System.Xml.XmlNamespaceManager]$nsm) {
  if (-not $nsm.HasNamespace('xsd')) { $nsm.AddNamespace('xsd', $XSD_NS) }
  return $nsm
}

function Load-Xml([string]$path) {
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $doc.Load($path)
  return $doc
}

function Ensure-Common-Headers([System.Xml.XmlDocument]$doc) {
  $schema = $doc.DocumentElement
  if (-not $schema -or $schema.LocalName -ne 'schema' -or $schema.NamespaceURI -ne $XSD_NS) {
    throw "Top element of '$($doc.BaseURI)' is not xsd:schema"
  }

  # require header values
  $schema.SetAttribute('targetNamespace', $CommonNs)
  $schema.SetAttribute('elementFormDefault','qualified')
  $schema.SetAttribute('attributeFormDefault','unqualified')
  if (-not $schema.HasAttribute('xmlns:c'))   { $schema.SetAttribute('xmlns:c',   $CommonNs) }
  if (-not $schema.HasAttribute('xmlns:tns')) { $schema.SetAttribute('xmlns:tns', $CommonNs) }
  if (-not $schema.HasAttribute('xmlns:xsd')) { $schema.SetAttribute('xmlns:xsd', $XSD_NS) }
}

function Ensure-ServiceHeaders([System.Xml.XmlDocument]$doc) {
  $schema = $doc.DocumentElement
  if (-not $schema.HasAttribute('xmlns:xsd')) { $schema.SetAttribute('xmlns:xsd', $XSD_NS) }
  if (-not $schema.HasAttribute('xmlns:c'))   { $schema.SetAttribute('xmlns:c',   $CommonNs) }
}

function Ensure-Import([System.Xml.XmlDocument]$doc, [string]$schemaLocation, [string]$ns) {
  $nsm = Add-NS (New-Object System.Xml.XmlNamespaceManager($doc.NameTable))
  $imports = $doc.DocumentElement.SelectNodes("/xsd:schema/xsd:import[@namespace='$ns']", $nsm)
  if ($imports.Count -eq 0) {
    $imp = $doc.CreateElement('xsd','import',$XSD_NS)
    $imp.SetAttribute('namespace', $ns)        | Out-Null
    $imp.SetAttribute('schemaLocation', $schemaLocation) | Out-Null
    $null = $doc.DocumentElement.PrependChild($imp)
    return $true
  } else {
    # normalize location if present
    if ($imports[0].GetAttribute('schemaLocation')) {
      $imports[0].SetAttribute('schemaLocation', $schemaLocation) | Out-Null
    }
    return $false
  }
}

function Remove-Local-Definition([System.Xml.XmlDocument]$doc, [string]$typeName) {
  $nsm = Add-NS (New-Object System.Xml.XmlNamespaceManager($doc.NameTable))
  $nodes = @()
  $nodes += $doc.SelectNodes("/xsd:schema/xsd:complexType[@name='$typeName']", $nsm)
  $nodes += $doc.SelectNodes("/xsd:schema/xsd:simpleType[@name='$typeName']",  $nsm)
  $removed = 0
  foreach ($n in $nodes) {
    $null = $n.ParentNode.RemoveChild($n)
    $removed++
  }
  return $removed
}

function Fix-Local-TypeReferences([System.Xml.XmlDocument]$doc, [string[]]$commonNames) {
  # prefix @type and @base where missing; use c: for common types, xsd: for built-ins
  $nsm = Add-NS (New-Object System.Xml.XmlNamespaceManager($doc.NameTable))

  $attrs = @()
  $attrs += $doc.SelectNodes("//@type", $nsm)
  $attrs += $doc.SelectNodes("//@base", $nsm)

  foreach ($a in $attrs) {
    $val = $a.Value
    if ([string]::IsNullOrWhiteSpace($val)) { continue }
    if ($val -match '^[a-zA-Z_][\w\.-]*:')   { continue } # already prefixed

    if ($BUILTINS -contains $val) {
      $a.Value = "xsd:$val"
    } elseif ($commonNames -contains $val) {
      $a.Value = "c:$val"
    } else {
      # leave as-is (could be tns: or another import)
    }
  }
}

# ------------- conflict logging -------------
$Conflicts = New-Object System.Collections.Generic.List[object]
function Add-ConflictLog {
  param(
    [string]$Type,
    [string]$ChosenFile,
    [string]$ChosenKind,
    [string[]]$OtherFiles,
    [int]$VariantCount
  )
  $Conflicts.Add([pscustomobject]@{
    Type       = $Type
    Variants   = $VariantCount
    ChosenKind = $ChosenKind
    ChosenFile = $ChosenFile
    OtherFiles = ($OtherFiles -join ';')
    PickedBy   = if ($AutoPick) {'autopick-first'} else {'manual'}
    Timestamp  = (Get-Date).ToString('s')
  })
}

# ---------------- load common ----------------
$commonDoc  = Load-Xml $CommonPath
Ensure-Common-Headers $commonDoc
$commonRoot = $commonDoc.DocumentElement

# collect names that already exist in common
$nsmCommon = Add-NS (New-Object System.Xml.XmlNamespaceManager($commonDoc.NameTable))
$existingCommon = @(
  @($commonDoc.SelectNodes('/xsd:schema/xsd:complexType[@name]', $nsmCommon)) +
  @($commonDoc.SelectNodes('/xsd:schema/xsd:simpleType[@name]',  $nsmCommon))
) | ForEach-Object { $_.GetAttribute('name') } | Sort-Object -Unique
$existingSet = [System.Collections.Generic.HashSet[string]]::new()
$null = $existingCommon.ForEach({ [void]$existingSet.Add($_) })

# -------------- scan service & root --------------
$files = foreach ($r in $Roots) { Get-ChildItem -Path $r -Filter *.xsd -Recurse -File } |
         Sort-Object FullName -Unique
if (-not $files) { Write-Host "No XSDs found under Roots." -ForegroundColor Yellow; exit 0 }

# find all requested type names present in the repos (for filtering OnlyTypes)
$foundNames = New-Object System.Collections.Generic.HashSet[string]
foreach ($f in $files) {
  $d = Load-Xml $f.FullName
  $nsm = Add-NS (New-Object System.Xml.XmlNamespaceManager($d.NameTable))
  @($d.SelectNodes('/xsd:schema/xsd:complexType[@name]', $nsm)) +
  @($d.SelectNodes('/xsd:schema/xsd:simpleType[@name]',  $nsm)) | ForEach-Object {
    [void]$foundNames.Add($_.GetAttribute('name'))
  }
}

$typesToProcess =
  if ($OnlyTypes.Count -gt 0) {
    $OnlyTypes | Where-Object { $foundNames.Contains($_) }
  } else {
    $foundNames
  }

Write-Host ("Types to process: {0}" -f ($typesToProcess.Count)) -ForegroundColor Cyan

# helper to get all defs of a type across files
function Get-Definitions([string]$t) {
  $defs = New-Object System.Collections.Generic.List[object]
  foreach ($f in $files) {
    $d   = Load-Xml $f.FullName
    $nsm = Add-NS (New-Object System.Xml.XmlNamespaceManager($d.NameTable))
    $hits = @()
    $hits += $d.SelectNodes("/xsd:schema/xsd:complexType[@name='$t']", $nsm)
    $hits += $d.SelectNodes("/xsd:schema/xsd:simpleType[@name='$t']",  $nsm)
    foreach ($h in $hits) {
      $defs.Add([pscustomobject]@{
        File = $f.FullName
        Kind = $h.LocalName            # complexType | simpleType
        Xml  = $h.OuterXml
        Doc  = $d
        Node = $h
      })
    }
  }
  return $defs
}

# -------------- main loop --------------
$addedToCommon   = 0
$removedLocals   = 0
$importsInserted = 0

foreach ($t in $typesToProcess) {
  # gather definitions
  $defs = Get-Definitions $t
  if ($defs.Count -eq 0) { continue }

  # group by exact XML to detect different variants
  $byXml = $defs | Group-Object { $_.Xml.Trim() }

  $chosen = $null

  if ($byXml.Count -gt 1) {
    if (-not $AutoPick) {
      Write-Warning "CONFLICT: '$t' has $($byXml.Count) different definitions; rerun with -AutoPick or resolve manually."
      continue
    }
    # choose first-seen variant
    $chosen  = $byXml[0].Group[0]
    $others  = ($byXml | ForEach-Object { $_.Group } | Where-Object { $_ -ne $chosen })
    Add-ConflictLog -Type $t -ChosenFile $chosen.File -ChosenKind $chosen.Kind `
      -OtherFiles ($others | ForEach-Object File) -VariantCount $byXml.Count
  } else {
    $chosen = $byXml[0].Group[0]
  }

  # ensure chosen type exists in common (append if missing)
  if (-not $existingSet.Contains($t)) {
    [xml]$tmp = New-Object System.Xml.XmlDocument
    $tmp.LoadXml($chosen.Xml)
    $imported = $commonDoc.ImportNode($tmp.DocumentElement, $true)
    $null = $commonRoot.AppendChild($imported)
    [void]$existingSet.Add($t)
    $addedToCommon++
  }

  # collect all current common type names for prefixing
  $nsmCommon = Add-NS (New-Object System.Xml.XmlNamespaceManager($commonDoc.NameTable))
  $commonNames = @(
    @($commonDoc.SelectNodes('/xsd:schema/xsd:complexType[@name]', $nsmCommon)) +
    @($commonDoc.SelectNodes('/xsd:schema/xsd:simpleType[@name]',  $nsmCommon))
  ) | ForEach-Object { $_.GetAttribute('name') } | Sort-Object -Unique

  # remove locals from OTHER files, add import, and fix refs
  foreach ($d in $defs) {
    $doc  = $d.Doc
    $file = $d.File
    if ($file -ne $chosen.File) {
      $removedLocals += Remove-Local-Definition $doc $t
      $importsInserted += [int](Ensure-Import $doc '..\Common\common.xsd' $CommonNs)
      Ensure-ServiceHeaders $doc
      Fix-Local-TypeReferences $doc ([string[]]$commonNames)
      $doc.Save($file)
    }
  }

  # also run the prefix fixer against the chosen file itself (safe) and save it
  $chosenDoc = $chosen.Doc
  Ensure-ServiceHeaders $chosenDoc
  Fix-Local-TypeReferences $chosenDoc ([string[]]$commonNames)
  $chosenDoc.Save($chosen.File)
}

# save common last
$commonDoc.Save($CommonPath)

# write conflict CSV
try {
  $Conflicts | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
  Write-Host ("Conflict log written to {0} ({1} rows)." -f (Resolve-Path $LogPath), $Conflicts.Count) -ForegroundColor Yellow
} catch {
  Write-Warning "Could not write conflict log: $($_.Exception.Message)"
}

Write-Host ("Done. Added to common: {0}, removed local copies: {1}, imports inserted: {2}" -f $addedToCommon,$removedLocals,$importsInserted) -ForegroundColor Green
