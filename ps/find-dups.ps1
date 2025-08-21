<# Find-XsdDuplicates.ps1
   Reports duplicate GLOBAL declarations in an XSD (element, complexType, simpleType,
   group, attributeGroup, attribute). Works whether the XSD uses a prefix (xs:) or not.
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$XsdPath,

  [Parameter()]
  [string]$OutCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (!(Test-Path -LiteralPath $XsdPath)) { throw "File not found: $XsdPath" }

# Read file once
$content = Get-Content -LiteralPath $XsdPath -Raw
$lines = $content -split "`r?`n"

# Build 0-based char index for line starts (for line# mapping)
$lineStarts = New-Object System.Collections.Generic.List[int]
$pos = 0
foreach ($ln in $lines) { $lineStarts.Add($pos) | Out-Null; $pos += ($ln.Length + [Environment]::NewLine.Length) }
function Get-LineNumber([int]$index) {
  $lo=0;$hi=$lineStarts.Count-1
  while($lo -le $hi){ $mid=[int](($lo+$hi)/2)
    if($lineStarts[$mid] -le $index){
      if($mid -eq $lineStarts.Count-1 -or $lineStarts[$mid+1] -gt $index){ return $mid+1 }
      $lo=$mid+1
    } else { $hi=$mid-1 }
  }
  1
}

# ----- Tag pass (optional prefix) to know parentage -----
# < [/]? [prefix:]? local ( ... ) [/?>]
$tagRe = [regex]'(?is)<\s*(/)?\s*(?:(?<pref>[A-Za-z_]\w*)\s*:\s*)?(?<local>[A-Za-z_]\w*)([^>]*?)(/)?\s*>'
$tags = New-Object System.Collections.ArrayList
foreach ($m in $tagRe.Matches($content)) {
  $null = $tags.Add([pscustomobject]@{
    Index     = $m.Index
    Length    = $m.Length
    IsClose   = [bool]$m.Groups[1].Value
    Prefix    = $m.Groups['pref'].Value
    LocalName = $m.Groups['local'].Value
    IsSelf    = [bool]$m.Groups[5].Value
  })
}

$stack    = New-Object System.Collections.Stack
$nodeInfo = @{}
foreach ($t in $tags) {
  if ($t.IsClose) { if ($stack.Count) { $null = $stack.Pop() }; continue }
  $parent = ($stack.Count) ? $stack.Peek() : $null
  $nodeInfo[$t.Index] = [pscustomobject]@{
    Index = $t.Index; Prefix = $t.Prefix; Local = $t.LocalName; IsSelf = $t.IsSelf
    ParentLocal = if ($parent) { $parent.Local } else { $null }
    ParentPref  = if ($parent) { $parent.Prefix } else { $null }
    IsDirectChildOfSchema = ($parent -ne $null -and $parent.Local -eq 'schema')
  }
  if (-not $t.IsSelf) { $stack.Push([pscustomobject]@{ Prefix=$t.Prefix; Local=$t.LocalName }) }
}

# ----- Find global declarations under *:schema (prefix optional) -----
$declRe = [regex]'(?is)
  <\s*(?:(?<pref>[A-Za-z_]\w*)\s*:\s*)?
     (?<kind>complexType|simpleType|element|group|attributeGroup|attribute)\b
     (?<attrs>[^>]*?)
  >
'

$decls = New-Object System.Collections.Generic.List[object]
foreach ($m in $declRe.Matches($content)) {
  $info = $nodeInfo[$m.Index]
  if ($null -eq $info -or -not $info.IsDirectChildOfSchema) { continue }

  $nameMatch = [regex]::Match($m.Groups['attrs'].Value, '(?i)\bname\s*=\s*"([^"]+)"')
  if (-not $nameMatch.Success) { continue }

  $decls.Add([pscustomobject]@{
    Kind = $m.Groups['kind'].Value
    Name = $nameMatch.Groups[1].Value
    Line = Get-LineNumber $m.Index
  })
}

if ($decls.Count -eq 0) {
  Write-Host "No global declarations found. (Are declarations included from other files? This tool only inspects '$XsdPath'.)"
  exit 0
}

# Duplicates (same Kind+Name)
$dups = $decls | Group-Object Kind, Name | Where-Object { $_.Count -gt 1 } | Sort-Object @{e={$_.Name}}, Count -Descending
# Cross-kind same Name
$cross = $decls | Group-Object Name | Where-Object { ($_.Group.Kind | Select-Object -Unique).Count -gt 1 } | Sort-Object Name

"=== Duplicate global declarations (same Kind + same Name) ==="
if (-not $dups) { "None." } else {
  foreach ($g in $dups) {
    $kind,$name = $g.Name -split ',\s*',2
    " - {0} '{1}' occurs {2} times at lines: {3}" -f $kind,$name,$g.Count, (($g.Group | Sort-Object Line | % Line) -join ', ')
  }
}

"`n=== Cross-kind name reuse (same Name across different Kinds) ==="
if (-not $cross) { "None." } else {
  foreach ($g in $cross) {
    $kinds = $g.Group.Kind | Select-Object -Unique
    if ($kinds.Count -gt 1) {
      " - Name '{0}' used by kinds: {1}. Lines: {2}" -f $g.Name, ($kinds -join ', '), (($g.Group | Sort-Object Line | % { "$($_.Kind)@L$($_.Line)" }) -join '; ')
    }
  }
}

if ($OutCsv) {
  $rows = foreach ($g in $dups) {
    $kind,$name = $g.Name -split ',\s*',2
    [pscustomobject]@{
      Kind  = $kind
      Name  = $name
      Count = $g.Count
      Lines = (($g.Group | Sort-Object Line | % Line) -join ', ')
    }
  }
  $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutCsv
  "`nWrote CSV -> $OutCsv"
}
