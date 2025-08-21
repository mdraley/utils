param(
  [Parameter(Mandatory=$true)]
  [string]$XsdPath,

  # Optional: write a JSON report
  [string]$OutJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $XsdPath)) {
  throw "XSD not found: $XsdPath"
}

# Read the file and parse with line-info
$content = Get-Content -LiteralPath $XsdPath -Raw
$loadOpts = [System.Xml.Linq.LoadOptions]::SetLineInfo
$xdoc = [System.Xml.Linq.XDocument]::Parse($content, $loadOpts)

# Root should be <xs:schema> but we ignore prefix and just take the root element.
$schema = $xdoc.Root
if ($schema.Name.LocalName -ne 'schema') {
  throw "Root element is not 'schema' (found '$($schema.Name)')."
}

# Helper: turn XML name into JAXB class name the same way XJC does in the default case.
function To-JaxbName([string]$xmlName) {
  if ([string]::IsNullOrWhiteSpace($xmlName)) { return $null }
  $parts = [regex]::Split($xmlName, '[^A-Za-z0-9]+') | Where-Object { $_ }
  ($parts | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join ''
}

# Collect global declarations (direct children of <schema>) that have @name
$wanted = @('element','complexType','simpleType')
$globals = @()

foreach ($child in $schema.Elements()) {
  if ($wanted -notcontains $child.Name.LocalName) { continue }
  $nameAttr = $child.Attribute([System.Xml.Linq.XName]::Get('name'))
  if ($null -eq $nameAttr) { continue }

  $lineInfo = ($child -as [System.Xml.IXmlLineInfo])
  $globals += [pscustomobject]@{
    Kind    = $child.Name.LocalName
    Name    = $nameAttr.Value
    Jaxb    = To-JaxbName $nameAttr.Value
    Line    = if ($lineInfo.HasLineInfo()) { $lineInfo.LineNumber } else { $null }
    Column  = if ($lineInfo.HasLineInfo()) { $lineInfo.LinePosition } else { $null }
  }
}

if ($globals.Count -eq 0) {
  Write-Host "No global declarations found."; exit 0
}

# Group by the default JAXB name and detect collisions
$collisions =
  $globals | Group-Object Jaxb | Where-Object { $_.Count -gt 1 } |
  ForEach-Object {
    [pscustomobject]@{
      JaxbName = $_.Name
      Count    = $_.Count
      Decls    = ($_.Group | Sort-Object Line, Column | Select-Object Kind,Name,Line,Column)
    }
  } | Sort-Object JaxbName

# Optional JSON report
if ($OutJson) {
  $collisions | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -Path $OutJson
}

# Pretty console output
if ($collisions.Count -eq 0) {
  Write-Host "✅ No JAXB name collisions detected." -ForegroundColor Green
} else {
  Write-Host "⚠️  JAXB name collisions:" -ForegroundColor Yellow
  foreach ($c in $collisions) {
    Write-Host ("  {0}  ({1} declarations)" -f $c.JaxbName, $c.Count)
    foreach ($d in $c.Decls) {
      $loc = if ($d.Line) { " @ L$($d.Line):C$($d.Column)" } else { "" }
      Write-Host ("      - {0,-11} {1}{2}" -f $d.Kind, $d.Name, $loc)
    }
  }
}
