<# 
.SYNOPSIS
  Find duplicate global declarations in an XSD.

.PARAMETER XsdPath
  Path to the XSD file (e.g., C:\code\encore\...\hostcomm.xsd)

.PARAMETER OutCsv
  Optional path to write a CSV with the duplicate details.

.NOTES
  - Looks for *global* declarations: element, complexType, simpleType, group,
    attributeGroup, attribute (i.e., direct children of xs:schema).
  - Reports duplicates per (Kind, Name) and also reports cross-kind name reuse.
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$XsdPath,

  [Parameter(Mandatory = $false)]
  [string]$OutCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (!(Test-Path -LiteralPath $XsdPath)) {
  throw "File not found: $XsdPath"
}

# Read file once
$content = Get-Content -LiteralPath $XsdPath -Raw
$lines = $content -split "`r?`n"

# Precompute 0-based character index of each line start for fast line-number mapping
$lineStarts = New-Object System.Collections.Generic.List[int]
$pos = 0
foreach ($ln in $lines) {
  $lineStarts.Add($pos) | Out-Null
  $pos += ($ln.Length + [Environment]::NewLine.Length)
}

function Get-LineNumber([int]$index) {
  # Binary search over lineStarts to find 1-based line number for a char index
  $lo = 0; $hi = $lineStarts.Count - 1
  while ($lo -le $hi) {
    $mid = [int](($lo + $hi) / 2)
    if ($lineStarts[$mid] -le $index) {
      if ($mid -eq $lineStarts.Count - 1 -or $lineStarts[$mid + 1] -gt $index) {
        return $mid + 1
      }
      $lo = $mid + 1
    } else {
      $hi = $mid - 1
    }
  }
  return 1
}

# Regex to capture *global* declarations (we’ll filter to top-level with a simple heuristic)
# Matches any prefix (xs/xsd/etc.) and one of the global kinds, with a name=""
$declRe = [regex]'(?is)
  <\s*(?<pref>[A-Za-z_]\w*)\s*:\s*(?<kind>complexType|simpleType|element|group|attributeGroup|attribute)\b
  (?<attrs>[^>]*?)
  >
'

# We’ll also roughly ensure it’s global by checking that there’s no closer opening tag
# for the same prefix:schema between file start and this match. Simpler: parse quickly
# whether this tag is a direct child of xs:schema by walking backward until previous "<"
# and counting schema depth. To keep it robust and fast, we’ll do a lightweight XML-path
# stack using another regex to find tags.

# Build a list of tags (open/close/self) with their index to compute depth/path.
$tagRe = [regex]'(?is)<\s*(/)?\s*([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*)([^>]*?)(/)?\s*>'
$tags = New-Object System.Collections.ArrayList
$mc = $tagRe.Matches($content)
foreach ($m in $mc) {
  $null = $tags.Add([pscustomobject]@{
    Index     = $m.Index
    Length    = $m.Length
    IsClose   = [bool]$m.Groups[1].Value
    Prefix    = $m.Groups[2].Value
    LocalName = $m.Groups[3].Value
    IsSelf    = [bool]$m.Groups[5].Value
  })
}

# Walk through tags to record the "schema depth" and whether a node is direct child of xs:schema
$stack = New-Object System.Collections.Stack
$nodeInfos = @{}  # key=index -> info
foreach ($t in $tags) {
  if ($t.IsClose) {
    if ($stack.Count -gt 0) { $null = $stack.Pop() }
    continue
  }

  $parent = ($stack.Count -gt 0) ? $stack.Peek() : $null
  $info = [pscustomobject]@{
    Index               = $t.Index
    Prefix              = $t.Prefix
    LocalName           = $t.LocalName
    IsSelf              = $t.IsSelf
    ParentLocal         = if ($parent) { $parent.LocalName } else { $null }
    ParentPrefix        = if ($parent) { $parent.Prefix } else { $null }
    IsDirectChildOfSchema = ($parent -ne $null -and $parent.LocalName -eq 'schema')
  }
  $nodeInfos[$t.Index] = $info

  if (-not $t.IsSelf) {
    $stack.Push([pscustomobject]@{ Prefix=$t.Prefix; LocalName=$t.LocalName })
  }
}

# Collect global declarations (direct children of *:schema) with name + kind + line
$declMatches = $declRe.Matches($content)
$decls = New-Object System.Collections.Generic.List[object]
foreach ($m in $declMatches) {
  $info = $nodeInfos[$m.Index]
  if ($null -eq $info -or -not $info.IsDirectChildOfSchema) { continue }

  # extract name="..."
  $nameMatch = [regex]::Match($m.Groups['attrs'].Value, '(?i)\bname\s*=\s*"([^"]+)"')
  if (-not $nameMatch.Success) { continue }

  $kind = $m.Groups['kind'].Value
  $name = $nameMatch.Groups[1].Value
  $line = Get-LineNumber $m.Index

  $decls.Add([pscustomobject]@{
    Kind = $kind
    Name = $name
    Line = $line
  })
}

if ($decls.Count -eq 0) {
  Write-Host "No global declarations found (did the schema use a different prefix than xs: ? This script supports any prefix, but tags must be under *:schema)."
  exit 0
}

# Group by (Kind, Name) to find true duplicates (count > 1)
$dups = $decls | Group-Object Kind, Name | Where-Object { $_.Count -gt 1 }

# Cross-kind reuse: same Name used by more than one Kind (e.g., element + complexType)
$cross = $decls | Group-Object Name | Where-Object { ($_.Group | Select-Object -Expand Kind -Unique).Count -gt 1 }

# --- Output ---
"=== Duplicate global declarations (same Kind + same Name) ==="
if ($dups.Count -eq 0) {
  "None."
} else {
  foreach ($g in $dups) {
    $kind,$name = $g.Name -split ',\s*',2
    " - {0} '{1}' occurs {2} times at lines: {3}" -f $kind,$name,$g.Count, (($g.Group | Sort-Object Line | ForEach-Object Line) -join ', ')
  }
}

"`n=== Cross-kind name reuse (same Name across different Kinds) ==="
if ($cross.Count -eq 0) {
  "None."
} else {
  foreach ($g in $cross) {
    $kinds = $g.Group | Select-Object -Expand Kind -Unique
    if ($kinds.Count -gt 1) {
      " - Name '{0}' used by kinds: {1}. Lines: {2}" -f $g.Name, ($kinds -join ', '), (($g.Group | Sort-Object Line | ForEach-Object { "$($_.Kind)@L$($_.Line)" }) -join '; ')
    }
  }
}

# Optional CSV
if ($OutCsv) {
  $rows = foreach ($g in $dups) {
    $kind,$name = $g.Name -split ',\s*',2
    [pscustomobject]@{
      Kind  = $kind
      Name  = $name
      Count = $g.Count
      Lines = (($g.Group | Sort-Object Line | ForEach-Object Line) -join ', ')
    }
  }
  $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutCsv
  "`nWrote CSV -> $OutCsv"
}
