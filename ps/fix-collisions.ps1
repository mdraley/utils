param(
  [Parameter(Mandatory=$true)] [string]$CollisionsJson,
  [Parameter(Mandatory=$true)] [string]$OutBindings,
  [string]$BasePackage = "com.example.xsd.common"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if(-not (Test-Path -LiteralPath $CollisionsJson)){ throw "Not found: $CollisionsJson" }

$data = Get-Content -Raw -LiteralPath $CollisionsJson | ConvertFrom-Json
$found = $data.Found
if(-not $found){ Write-Host "Nothing to fix (no collisions)."; exit 0 }

# Create deterministic suffix per JAXB name so re-runs are stable
function ShortHash([string]$s){
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $bytes = [Text.Encoding]::UTF8.GetBytes($s)
  $hash  = $sha.ComputeHash($bytes)
  # 3 bytes -> 6 hex chars
  ($hash[0..2] | % { $_.ToString("x2") }) -join ''
}

$pkgByJaxb = @{}
foreach($c in $found){
  # only act when Count > 1
  if($c.Count -le 1){ continue }
  $suffix = ShortHash $c.JaxbName
  $pkgByJaxb[$c.JaxbName] = "$BasePackage.c$($suffix)"
}

# Emit bindings
$ns = "https://jakarta.ee/xml/ns/jaxb"
$xs = "http://www.w3.org/2001/XMLSchema"

$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine("<?xml version=`"1.0`" encoding=`"UTF-8`"?>")
$null = $sb.AppendLine("<jaxb:bindings xmlns:jaxb='$ns' xmlns:xs='$xs' version='3.0'>")

# One schema-level block that sets package for each colliding JAXB name by class customization
# We target all declarations and then set <jaxb:class name="..."> with a package.
foreach($c in $found){
  if($c.Count -le 1){ continue }
  $pkg = $pkgByJaxb[$c.JaxbName]
  # Make a class customization entry; we can match by class name with a wildcard node selector
  # XJC accepts <jaxb:bindings> at schema level with multiple <jaxb:class> customizations.
  $null = $sb.AppendLine("  <jaxb:bindings>")
  $null = $sb.AppendLine("    <jaxb:class ref='${($c.JaxbName)}' name='${($c.JaxbName)}'>")
  $null = $sb.AppendLine("      <jaxb:package name='$pkg'/>")
  $null = $sb.AppendLine("    </jaxb:class>")
  $null = $sb.AppendLine("  </jaxb:bindings>")
}

$null = $sb.AppendLine("</jaxb:bindings>")
$sb.ToString() | Set-Content -LiteralPath $OutBindings -Encoding UTF8

Write-Host "Wrote bindings -> $OutBindings"
