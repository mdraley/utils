param(
  [Parameter(Mandatory=$true)]
  [string]$XsdPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (!(Test-Path -LiteralPath $XsdPath)) {
  throw "Not found: $XsdPath"
}

# --- helpers ---------------------------------------------------------------

function Get-LineMap([string]$text) {
  $starts = New-Object System.Collections.Generic.List[int]
  $starts.Add(0) | Out-Null
  for ($i=0; $i -lt $text.Length; $i++) {
    if ($text[$i] -eq "`n") { $starts.Add($i+1) | Out-Null }
  }
  return $starts
}

function LineCol([System.Collections.Generic.List[int]]$starts, [int]$pos) {
  # binary search for line start <= pos
  $lo = 0; $hi = $starts.Count-1
  while ($lo -le $hi) {
    $mid = [int](($lo+$hi)/2)
    if ($starts[$mid] -le $pos) { $lo = $mid + 1 } else { $hi = $mid - 1 }
  }
  $line = $hi + 1         # 1-based
  $col  = $pos - $starts[$hi] + 1
  [PSCustomObject]@{ Line=$line; Col=$col }
}

# JAXB-ish simple name conversion: split on non-alnum and case changes
function To-JaxbName([string]$xmlName) {
  if ([string]::IsNullOrWhiteSpace($xmlName)) { return $null }
  $parts = @()
  $buf = ""
  for ($i=0; $i -lt $xmlName.Length; $i++) {
    $ch = $xmlName[$i]
    if ($ch -match '[A-Za-z0-9]') {
      # break when a lower->upper transition occurs (XmlWord -> Xml + Word)
      if ($buf.Length -gt 0 -and
          $buf[$buf.Length-1] -match '[a-z]' -and
          $ch -match '[A-Z]') {
        $parts += ,$buf; $buf = ""
      }
      $buf += $ch
    } else {
      if ($buf.Length -gt 0) { $parts += ,$buf; $buf = "" }
    }
  }
  if ($buf.Length -gt 0) { $parts += ,$buf }

  # capitalize words and join
  $cap = $parts | ForEach-Object {
    if ($_ -match '^[A-Za-z]') { $_.Substring(0,1).ToUpper() + $_.Substring(1) } else { $_ }
  }
  ($cap -join '')
}

# --- scan ------------------------------------------------------------------

$xmlText = Get-Content -LiteralPath $XsdPath -Raw
$lineMap = Get-LineMap $xmlText

# quick-and-robust parse via regex for *global* declarations under the root schema
# (this works regardless of the chosen prefix; it looks for :schema and :element/:complexType/:simpleType)
$schemaOpen  = [regex]'(?is)<\s*([A-Za-z0-9_]+):schema\b'
$schemaClose = [regex]'(?is)</\s*([A-Za-z0-9_]+):schema\s*>'

$openMatch = $schemaOpen.Match($xmlText)
if (-not $openMatch.Success) { throw "No <*:schema> found." }

# find the matching close by counting nested <*:schema>
$prefix = $openMatch.Groups[1].Value
$depth = 0
$pos = $openMatch.Index
$end = $null
while ($pos -lt $xmlText.Length) {
  $m1 = $schemaOpen.Match($xmlText, $pos)
  $m2 = $schemaClose.Match($xmlText, $pos)
  if ($m2.Success -and ($m1.Success -eq $false -or $m2.Index -lt $m1.Index)) {
    if ($m2.Groups[1].Value -eq $prefix) {
      if ($depth -eq 0) { $end = $m2.Index; break } else { $depth-- }
    }
    $pos = $m2.Index + $m2.Length
  } elseif ($m1.Success) {
    if ($m1.Groups[1].Value -eq $prefix) { $depth++ }
    $pos = $m1.Index + $m1.Length
  } else { break }
}
if ($end -eq $null) { throw "Could not find </$prefix:schema>." }

# within the top-level schema, pull global element/complexType/simpleType
$body = $xmlText.Substring($openMatch.Index, $end - $openMatch.Index)

$declRe = [regex]::new("(?is)<\s*$prefix:(element|complexType|simpleType)\b[^>]*\bname\s*=\s*""([^""]+)""", 'IgnoreCase')

$globals = New-Object System.Collections.Generic.List[object]

foreach ($m in $declRe.Matches($body)) {
  $kind = $m.Groups[1].Value
  $name = $m.Groups[2].Value
  $abs  = $openMatch.Index + $m.Index
  $lc   = LineCol $lineMap $abs
  $globals.Add([PSCustomObject]@{
      Kind=$kind; Name=$name; JaxbName=(To-JaxbName $name); Line=$lc.Line; Col=$lc.Col
  })
}

if ($globals.Count -eq 0) { Write-Host "No global declarations found."; exit 0 }

# duplicates by exact XML name within same kind
$dupes = $globals | Group-Object Kind,Name | Where-Object { $_.Count -gt 1 }
# potential ObjectFactory collisions (same JAXB name among elements; and among types)
$elemCollide = $globals | Where-Object {$_.Kind -eq 'element'} |
               Group-Object JaxbName | Where-Object { $_.Name -ne '' -and $_.Count -gt 1 }
$typeCollide = $globals | Where-Object {$_.Kind -ne 'element'} |
               Group-Object JaxbName | Where-Object { $_.Name -ne '' -and $_.Count -gt 1 }

Write-Host ""
Write-Host "=== Summary for $XsdPath ==="
Write-Host ("Globals: {0}  (elements: {1}, types: {2})" -f `
  $globals.Count,
  ($globals | Where-Object {$_.Kind -eq 'element'}).Count,
  ($globals | Where-Object {$_.Kind -ne 'element'}).Count)

if ($dupes.Count -gt 0) {
  Write-Host "`n-- Exact duplicate XML names --"
  foreach ($g in $dupes) {
    $k,$n = $g.Name -split ','
    Write-Host ("{0} '{1}' appears {2} times:" -f $k.Trim(), $n.Trim(), $g.Count)
    $g.Group | Sort-Object Line | ForEach-Object {
      Write-Host ("   line {0,6} col {1,3}" -f $_.Line,$_.Col)
    }
  }
} else {
  Write-Host "`n-- No exact duplicate XML names found."
}

if ($elemCollide.Count -gt 0 -or $typeCollide.Count -gt 0) {
  Write-Host "`n-- Potential ObjectFactory name collisions --"
  foreach ($g in @($elemCollide + $typeCollide)) {
    Write-Host ("JAXB name '{0}' occurs {1} times:" -f $g.Name,$g.Count)
    $g.Group | Sort-Object Line | ForEach-Object {
      Write-Host ("   {0,-12} xml='{1}' @ line {2}" -f $_.Kind, $_.Name, $_.Line)
    }
  }
} else {
  Write-Host "`n-- No ObjectFactory name collisions detected (with simple JAXB name mapping)."
}

# Handy: dump a CSV next to the XSD so you can filter/sort in Excel
$outCsv = [IO.Path]::ChangeExtension($XsdPath, '.globals.csv')
$globals | Sort-Object Kind, Name | Export-Csv -NoTypeInformation -Encoding UTF8 $outCsv
Write-Host "`nWrote globals list -> $outCsv"
