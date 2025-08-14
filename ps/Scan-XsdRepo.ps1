param(
  [Parameter(Mandatory=$true)][string]$Root,
  [string]$OutDir = "xsd_scan_out"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Ensure output dir
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# CSV writers
$importsCsv = Join-Path $OutDir "imports.csv"
$defsCsv    = Join-Path $OutDir "definitions.csv"
$usageCsv   = Join-Path $OutDir "usage.csv"
$summaryMd  = Join-Path $OutDir "SUMMARY.md"

"# file,targetNamespace,import_namespace,schemaLocation" | Out-File -FilePath $importsCsv -Encoding utf8
" " | Out-File -FilePath $importsCsv -Append -Encoding utf8
"# file,targetNamespace,include_schemaLocation" | Out-File -FilePath $importsCsv -Append -Encoding utf8

"# file,targetNamespace,kind,name,qname" | Out-File -FilePath $defsCsv -Encoding utf8
"# ref_file,ref_file_ns,kind,attr,ref_ns,ref_name,defined_here,def_files" | Out-File -FilePath $usageCsv -Encoding utf8

# Namespace manager helper
function New-NsMgr([System.Xml.XmlDocument]$doc){
  $nsmgr = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  $nsmgr.AddNamespace("xs","http://www.w3.org/2001/XMLSchema") | Out-Null
  return $nsmgr
}

# Parse one schema
function Parse-Xsd([string]$file){
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $doc.Load($file)
  $nsmgr = New-NsMgr $doc
  $root = $doc.DocumentElement
  $tns = $root.GetAttribute("targetNamespace")

  # Build nsmap (prefix->uri, include default via key '')
  $nsmap = @{}
  foreach($attr in $root.Attributes){
    if($attr.Name -like "xmlns:*"){
      $prefix = $attr.Name.Split(":")[1]
      $nsmap[$prefix] = $attr.Value
    } elseif ($attr.Name -eq "xmlns"){
      $nsmap[""] = $attr.Value
    }
  }

  # imports
  $imports = $root.SelectNodes(".//xs:import",$nsmgr)
  foreach($imp in $imports){
    $ns  = $imp.GetAttribute("namespace")
    $loc = $imp.GetAttribute("schemaLocation")
    "$file,$tns,$ns,$loc" | Out-File -FilePath $importsCsv -Append -Encoding utf8
  }
  # includes
  $includes = $root.SelectNodes(".//xs:include",$nsmgr)
  foreach($inc in $includes){
    $loc = $inc.GetAttribute("schemaLocation")
    "$file,$tns,$loc" | Out-File -FilePath $importsCsv -Append -Encoding utf8
  }

  # globals
  $globals = @()
  foreach($kind in "complexType","simpleType","element","attributeGroup","group"){
    $nodes = $root.SelectNodes("./xs:$kind",$nsmgr)
    foreach($n in $nodes){
      $name = $n.GetAttribute("name")
      if([string]::IsNullOrEmpty($name)){ continue }
      $qname = if($tns){ "{${tns}}$name" } else { $name }
      "$file,$tns,$kind,$name,$qname" | Out-File -FilePath $defsCsv -Append -Encoding utf8
      $globals += [pscustomobject]@{ kind=$kind; name=$name; qname=$qname }
    }
  }

  # refs
  $refs = @()
  $pairs = @(
    @{node="element"; attr="type"},
    @{node="attribute"; attr="type"},
    @{node="extension"; attr="base"},
    @{node="restriction"; attr="base"},
    @{node="list"; attr="itemType"}
  )
  foreach($p in $pairs){
    $nodes = $root.SelectNodes(".//xs:{0}" -f $p.node,$nsmgr)
    foreach($n in $nodes){
      $val = $n.GetAttribute($p.attr)
      if([string]::IsNullOrWhiteSpace($val)){ continue }
      $refs += [pscustomobject]@{ kind=$p.node; attr=$p.attr; qname=$val }
    }
  }
  $unions = $root.SelectNodes(".//xs:union",$nsmgr)
  foreach($u in $unions){
    $mt = $u.GetAttribute("memberTypes")
    if([string]::IsNullOrWhiteSpace($mt)){ continue }
    foreach($part in $mt.Split(" ",[System.StringSplitOptions]::RemoveEmptyEntries)){
      $refs += [pscustomobject]@{ kind="union"; attr="memberTypes"; qname=$part }
    }
  }

  # resolve qnames using nsmap
  foreach($r in $refs){
    $q = $r.qname.Trim()
    $prefix=""; $local=$q; $ns=$null
    if($q -match ":"){
      $prefix,$local = $q.Split(":",2)
      $ns = $nsmap[$prefix]
    } else {
      $ns = $nsmap[""]
    }
    $r | Add-Member -NotePropertyName prefix -NotePropertyValue $prefix
    $r | Add-Member -NotePropertyName local  -NotePropertyValue $local
    $r | Add-Member -NotePropertyName ns     -NotePropertyValue $ns
  }

  return [pscustomobject]@{
    file=$file; tns=$tns; nsmap=$nsmap; globals=$globals; refs=$refs
  }
}

# Scan repo
$files = Get-ChildItem -Path $Root -Recurse -File -Filter *.xsd
$results = @()
foreach($f in $files){
  try{
    $results += Parse-Xsd $f.FullName
  } catch {
    Write-Warning "Failed to parse $($f.FullName): $_"
  }
}

# Build def map (ns,name) -> files
$defMap = @{}
foreach($r in $results){
  foreach($g in $r.globals){
    $ns = $r.tns
    $key = "$ns||$($g.name)"
    if(-not $defMap.ContainsKey($key)){ $defMap[$key] = New-Object System.Collections.Generic.HashSet[string] }
    $null = $defMap[$key].Add($r.file)
  }
}

# usage.csv
foreach($r in $results){
  foreach($ref in $r.refs){
    if([string]::IsNullOrWhiteSpace($ref.local)){ continue }
    $key = "$($ref.ns)||$($ref.local)"
    $defs = if($defMap.ContainsKey($key)){ ($defMap[$key] -join ";") } else { "" }
    $definedHere = ($defs -split ";" | Where-Object { $_ -eq $r.file }) -ne $null
    "$($r.file),$($r.tns),$($ref.kind),$($ref.attr),$($ref.ns),$($ref.local),$definedHere,$defs" | `
      Out-File -FilePath $usageCsv -Append -Encoding utf8
  }
}

# SUMMARY.md
$nsImportCounts = @{}
foreach($r in $results){
  $doc = [xml](Get-Content -Raw -Encoding UTF8 $r.file)
  $nsmgr = New-NsMgr $doc
  $imports = $doc.DocumentElement.SelectNodes(".//xs:import",$nsmgr)
  $seen = New-Object System.Collections.Generic.HashSet[string]
  foreach($imp in $imports){
    $ns = $imp.GetAttribute("namespace")
    if([string]::IsNullOrWhiteSpace($ns)){ continue }
    $null = $seen.Add($ns)
  }
  foreach($ns in $seen){
    if(-not $nsImportCounts.ContainsKey($ns)){ $nsImportCounts[$ns] = 0 }
    $nsImportCounts[$ns] += 1
  }
}

# cross-file reused types
$usageRows = Import-Csv -Path $usageCsv
$cross = @{}
foreach($row in $usageRows){
  if($row.defined_here -eq "True"){ continue }
  $key = "$($row.ref_ns)||$($row.ref_name)"
  if(-not $cross.ContainsKey($key)){ $cross[$key] = New-Object System.Collections.Generic.HashSet[string] }
  $null = $cross[$key].Add($row.ref_file)
}

$lines = @("# XSD Scan Summary", "", "## Most imported namespaces (good common candidates)")
foreach($kv in ($nsImportCounts.GetEnumerator() | Sort-Object -Property Value -Descending)){
  $lines += ("- `{0}` imported by {1} file(s)" -f $kv.Key, $kv.Value)
}
$lines += @("", "## Types used across files but defined elsewhere (top 50)")
$top = $cross.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | Select-Object -First 50
$lines += ($top | ForEach-Object {
  $ns,$name = $_.Key.Split("||",2)
  $defFiles = if($defMap.ContainsKey($_.Key)){ ($defMap[$_.Key] -join ";") } else { "" }
  "{0}. `{1}` in `{2}` referenced by {3} file(s). Defined in: {4}" -f `
    (++$i), $name, $ns, $_.Value.Count, $defFiles
})
$lines | Out-File -FilePath $summaryMd -Encoding utf8

Write-Host "Wrote:"
Write-Host " - $importsCsv"
Write-Host " - $defsCsv"
Write-Host " - $usageCsv"
Write-Host " - $summaryMd"
