param(
  [Parameter(Mandatory=$true)]
  [string]$XsdPath,                             # e.g. C:\code\encore\...\schema\host-comm\hostcomm.xsd

  [Parameter(Mandatory=$true)]
  [string]$OutBindingPath                        # e.g. C:\code\encore\...\schema\host-comm\binding.xjb
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Helpers ---------------------------------------------------------------

function To-JaxbName([string]$xmlName) {
  if ([string]::IsNullOrWhiteSpace($xmlName)) { return $null }

  # split on non-alnum and boundaries; keep letters/digits; camelize
  $parts = [System.Text.RegularExpressions.Regex]::Split($xmlName,'[^A-Za-z0-9]+') |
           Where-Object { $_ -ne '' }

  if ($parts.Count -eq 0) { $parts = @($xmlName) }

  $cap = foreach($p in $parts) {
    if ($p.Length -eq 0) { continue }
    $p = $p.ToLower()
    $p = $p.Substring(0,1).ToUpper() + (if ($p.Length -gt 1) { $p.Substring(1) } else { '' })
    $p
  }
  $name = ($cap -join '')

  # if starts with a digit, prefix with _
  if ($name.Length -gt 0 -and [char]::IsDigit($name[0])) { $name = "_$name" }

  return $name
}

function Load-Xsd([string]$path) {
  $xml = New-Object System.Xml.XmlDocument
  $xml.PreserveWhitespace = $true
  $xml.Load($path)
  return $xml
}

# Returns a record for each global declaration
function Get-Globals([System.Xml.XmlDocument]$doc) {
  $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  $ns.AddNamespace('xs','http://www.w3.org/2001/XMLSchema')

  $globals = New-Object System.Collections.Generic.List[object]

  # global elements
  foreach ($el in $doc.SelectNodes('/xs:schema/xs:element[@name]',$ns)) {
    $n = $el.Attributes['name'].Value
    $decl = [PSCustomObject]@{
      Kind       = 'element'
      XmlName    = $n
      JaxbBase   = To-JaxbName $n        # element class name, if generated
      NodeXPath  = "//xs:element[@name='$n']"
    }
    $globals.Add($decl)
  }

  # named complex types
  foreach ($ct in $doc.SelectNodes('/xs:schema/xs:complexType[@name]',$ns)) {
    $n = $ct.Attributes['name'].Value
    $decl = [PSCustomObject]@{
      Kind       = 'complexType'
      XmlName    = $n
      JaxbBase   = To-JaxbName $n        # type class name
      NodeXPath  = "//xs:complexType[@name='$n']"
    }
    $globals.Add($decl)
  }

  # named simple types
  foreach ($st in $doc.SelectNodes('/xs:schema/xs:simpleType[@name]',$ns)) {
    $n = $st.Attributes['name'].Value
    $decl = [PSCustomObject]@{
      Kind       = 'simpleType'
      XmlName    = $n
      JaxbBase   = To-JaxbName $n
      NodeXPath  = "//xs:simpleType[@name='$n']"
    }
    $globals.Add($decl)
  }

  return $globals
}

function Suffix-ByIntent([string]$xmlName, [string]$kind) {
  # Prefer Rq/Rs-aware suffixes for readability
  $rq = $xmlName -match '(?i)\bRq\b|Rq(Type)?'
  $rs = $xmlName -match '(?i)\bRs\b|Rs(Type)?'

  if ($kind -eq 'element') {
    if ($rq) { return 'RqElem' }
    if ($rs) { return 'RsElem' }
    return 'Elem'
  } else {
    if ($rq) { return 'RqType' }
    if ($rs) { return 'RsType' }
    return 'Type'
  }
}

# Make a unique Java name given a base & preferred suffix
function Make-UniqueName([string]$base, [string]$suffix, [HashSet[string]]$used) {
  $candidate = "$base$suffix"
  $i = 2
  while ($used.Contains($candidate)) {
    $candidate = "$base$suffix$i"
    $i++
  }
  $used.Add($candidate) | Out-Null
  return $candidate
}

# --- Main ------------------------------------------------------------------

$absXsd = (Resolve-Path $XsdPath).Path
$doc = Load-Xsd $absXsd
$globals = Get-Globals $doc

if ($globals.Count -eq 0) {
  Write-Error "No global declarations found in $absXsd"
  exit 1
}

# Simulate generated Java names BEFORE suffixing so we can see collisions.
# Two main buckets: "element-class names" and "type-class names"
$byJava = @{}  # javaName -> list of globals (kind, xmlname, xPath)

foreach ($g in $globals) {
  $java = $g.JaxbBase
  if (-not $byJava.ContainsKey($java)) { $byJava[$java] = New-Object System.Collections.Generic.List[object] }
  $byJava[$java].Add($g)
}

# Compute rename plan for buckets with >1 entries or (optional) element-vs-type clashes we want to avoid.
$renamePlan = New-Object 'System.Collections.Generic.List[object]'
$allAssigned = New-Object 'System.Collections.Generic.HashSet[string]'

foreach ($kvp in $byJava.GetEnumerator()) {
  $javaBase = $kvp.Key
  $items = $kvp.Value

  if ($items.Count -eq 1) {
    # Still claim this base name so later suffixes don’t accidentally reuse it.
    $allAssigned.Add($javaBase) | Out-Null
    continue
  }

  foreach ($g in $items) {
    $suffix = Suffix-ByIntent $g.XmlName $g.Kind
    $unique = Make-UniqueName $javaBase $suffix $allAssigned

    $renamePlan.Add([PSCustomObject]@{
      Kind     = $g.Kind
      XmlName  = $g.XmlName
      Node     = $g.NodeXPath
      NewJava  = $unique
      BaseJava = $javaBase
    })
  }
}

if ($renamePlan.Count -eq 0) {
  Write-Host "No collisions detected. Nothing to rename."
  # Still produce a minimal binding with your packages if you want; otherwise exit.
}

# Build binding.xjb
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$sb.AppendLine('<jaxb:bindings xmlns:jaxb="https://jakarta.ee/xml/ns/jaxb"')
[void]$sb.AppendLine('               xmlns:xs="http://www.w3.org/2001/XMLSchema"')
[void]$sb.AppendLine('               version="3.0">')
[void]$sb.AppendLine('  <!-- Auto-generated by make-binding-for-collisions.ps1 -->')

foreach ($r in $renamePlan) {
  $node = $r.Node
  $newName = $r.NewJava
  [void]$sb.AppendLine("  <jaxb:bindings node=""$node"">")
  [void]$sb.AppendLine("    <jaxb:class name=""$newName""/>")
  [void]$sb.AppendLine("  </jaxb:bindings>")
}

[void]$sb.AppendLine('</jaxb:bindings>')

$bindingDir = Split-Path -Parent $OutBindingPath
New-Item -ItemType Directory -Force -Path $bindingDir | Out-Null
$sb.ToString() | Set-Content -Path $OutBindingPath -Encoding UTF8

Write-Host "Wrote binding with $($renamePlan.Count) rename(s): $OutBindingPath"
