param(
  [Parameter(Mandatory=$true)][string]$Root,
  [Parameter(Mandatory=$true)][string]$Namespace,
  [Parameter(Mandatory=$true)][string]$Name,
  [string]$OutDir = "type_closure_out"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$nodesCsv = Join-Path $OutDir "nodes.csv"
$edgesCsv = Join-Path $OutDir "edges.csv"
$summaryMd = Join-Path $OutDir "SUMMARY.md"

"# name,namespace,kind,file,anonymous_type_count,facet_count" | Out-File -FilePath $nodesCsv -Encoding utf8
"# from_type,relation,to_namespace,to_type" | Out-File -FilePath $edgesCsv -Encoding utf8

function New-NsMgr([System.Xml.XmlDocument]$doc){
  $nsmgr = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  $nsmgr.AddNamespace("xs","http://www.w3.org/2001/XMLSchema") | Out-Null
  return $nsmgr
}

# Index global definitions: (ns,name,kind) -> list of (file, node)
$index = @{}
$docs  = @{}
$files = Get-ChildItem -Path $Root -Recurse -File -Filter *.xsd
foreach($f in $files){
  try{
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($f.FullName)
    $docs[$f.FullName] = $doc
    $nsmgr = New-NsMgr $doc
    $root = $doc.DocumentElement
    $tns = $root.GetAttribute("targetNamespace")
    foreach($kind in "complexType","simpleType","element","attributeGroup","group"){
      $nodes = $root.SelectNodes("./xs:$kind",$nsmgr)
      foreach($n in $nodes){
        $name = $n.GetAttribute("name")
        if([string]::IsNullOrWhiteSpace($name)){ continue }
        $key = "$tns||$name||$kind"
        if(-not $index.ContainsKey($key)){ $index[$key] = @() }
        $index[$key] += ,@($f.FullName, $n)
      }
    }
  } catch {
    Write-Warning "Parse failed $($f.FullName): $_"
  }
}

# Find start node (prefer complex/simpleType)
$start = $null
foreach($kind in "complexType","simpleType"){
  $k = "$Namespace||$Name||$kind"
  if($index.ContainsKey($k)){
    $start = $index[$k][0]
    break
  }
}
if(-not $start){
  throw "Type $Namespace::$Name not found."
}

$queue = New-Object System.Collections.Queue
$seen  = New-Object System.Collections.Generic.HashSet[string]
$edges = New-Object System.Collections.Generic.List[object]
$nodes = New-Object System.Collections.Generic.List[object]

$queue.Enqueue($start)
$null = $seen.Add(($start[0] + "|" + $start[1].OuterXml))

function Add-EdgesAndEnqueue($file,$node,$nsmap){
  param()
  # helper: resolve QName using nsmap
  function Resolve-QName([string]$q){
    if([string]::IsNullOrWhiteSpace($q)){ return $null }
    if($q.Contains(":")){
      $parts = $q.Split(":",2)
      $pref = $parts[0]; $local = $parts[1]
      $uri = $nsmap[$pref]
      return @($uri,$local)
    } else {
      $uri = $nsmap[""]
      return @($uri,$q)
    }
  }
  # facets collector
  function Collect-Facets($restrict){
    $facetNames = "length","minLength","maxLength","pattern","enumeration","minInclusive","maxInclusive","minExclusive","maxExclusive","totalDigits","fractionDigits","whiteSpace"
    $cnt = 0
    foreach($fn in $facetNames){
      $cnt += $restrict.SelectNodes("xs:$fn",$script:nsmgr).Count
    }
    return $cnt
  }

  $doc = $docs[$file]
  $script:nsmgr = New-NsMgr $doc
  $root = $doc.DocumentElement
  # Build nsmap from root xmlns
  $nsmap = @{}
  foreach($attr in $root.Attributes){
    if($attr.Name -like "xmlns:*"){
      $prefix = $attr.Name.Split(":")[1]
      $nsmap[$prefix] = $attr.Value
    } elseif ($attr.Name -eq "xmlns"){
      $nsmap[""] = $attr.Value
    }
  }

  # record node
  $tns = $root.GetAttribute("targetNamespace")
  $kind = $node.Name -replace ".*:", ""
  $anonCount = ($node.SelectNodes(".//xs:complexType[not(@name)] | .//xs:simpleType[not(@name)]",$script:nsmgr)).Count
  $facetCount = 0
  foreach($r in $node.SelectNodes(".//xs:restriction",$script:nsmgr)){
    $facetCount += (Collect-Facets $r)
  }
  "{0},{1},{2},{3},{4},{5}" -f $Name,$tns,$kind,$file,$anonCount,$facetCount | Out-File -FilePath $nodesCsv -Append -Encoding utf8

  # relations
  $pairs = @(
    @{xp=".//xs:restriction"; rel="restriction:base"; attr="base"},
    @{xp=".//xs:extension";   rel="extension:base";   attr="base"},
    @{xp=".//xs:list";        rel="list:itemType";    attr="itemType"},
    @{xp=".//xs:union";       rel="union:memberTypes";attr="memberTypes"}
  )
  foreach($p in $pairs){
    $nodes2 = $node.SelectNodes($p.xp,$script:nsmgr)
    foreach($n2 in $nodes2){
      $val = $n2.GetAttribute($p.attr)
      if([string]::IsNullOrWhiteSpace($val)){ continue }
      if($p.rel -eq "union:memberTypes"){
        foreach($part in $val.Split(" ",[System.StringSplitOptions]::RemoveEmptyEntries)){
          $r = Resolve-QName $part
          if($r){
            "{0},{1},{2},{3}" -f $Name,$p.rel,$r[0],$r[1] | Out-File -FilePath $edgesCsv -Append -Encoding utf8
            foreach($kind2 in "complexType","simpleType"){
              $k = "{0}||{1}||{2}" -f $r[0],$r[1],$kind2
              if($index.ContainsKey($k)){
                foreach($cand in $index[$k]){
                  $key = $cand[0] + "|" + $cand[1].OuterXml
                  if(-not $seen.Contains($key)){
                    $seen.Add($key) | Out-Null
                    $queue.Enqueue($cand)
                  }
                }
              }
            }
          }
        }
      } else {
        $r = Resolve-QName $val
        if($r){
          "{0},{1},{2},{3}" -f $Name,$p.rel,$r[0],$r[1] | Out-File -FilePath $edgesCsv -Append -Encoding utf8
          foreach($kind2 in "complexType","simpleType"){
            $k = "{0}||{1}||{2}" -f $r[0],$r[1],$kind2
            if($index.ContainsKey($k)){
              foreach($cand in $index[$k]){
                $key = $cand[0] + "|" + $cand[1].OuterXml
                if(-not $seen.Contains($key)){
                  $seen.Add($key) | Out-Null
                  $queue.Enqueue($cand)
                }
              }
            }
          }
        }
      }
    }
  }

  foreach($pair in @(@{tag="element";attr="type"}, @{tag="attribute";attr="type"})){
    $nodes3 = $node.SelectNodes(".//xs:{0}" -f $pair.tag, $script:nsmgr)
    foreach($n3 in $nodes3){
      $val = $n3.GetAttribute($pair.attr)
      if([string]::IsNullOrWhiteSpace($val)){ continue }
      $r = Resolve-QName $val
      if($r){
        "{0},{1}:{2},{3},{4}" -f $Name,$pair.tag,$pair.attr,$r[0],$r[1] | Out-File -FilePath $edgesCsv -Append -Encoding utf8
        foreach($kind2 in "complexType","simpleType"){
          $k = "{0}||{1}||{2}" -f $r[0],$r[1],$kind2
          if($index.ContainsKey($k)){
            foreach($cand in $index[$k]){
              $key = $cand[0] + "|" + $cand[1].OuterXml
              if(-not $seen.Contains($key)){
                $seen.Add($key) | Out-Null
                $queue.Enqueue($cand)
              }
            }
          }
        }
      }
    }
  }

  foreach($t in "group","attributeGroup"){
    $nodes4 = $node.SelectNodes(".//xs:{0}" -f $t, $script:nsmgr)
    foreach($n4 in $nodes4){
      $ref = $n4.GetAttribute("ref")
      if([string]::IsNullOrWhiteSpace($ref)){ continue }
      $parts = $ref.Split(":",2)
      if($parts.Count -eq 2){
        $pref,$local = $parts
        $uri = $nsmap[$pref]
      } else {
        $local = $ref; $uri = $nsmap[""]
      }
      "{0},{1}:ref,{2},{3}" -f $Name,$t,$uri,$local | Out-File -FilePath $edgesCsv -Append -Encoding utf8
      $k = "{0}||{1}||{2}" -f $uri,$local,$t
      if($index.ContainsKey($k)){
        foreach($cand in $index[$k]){
          $key = $cand[0] + "|" + $cand[1].OuterXml
          if(-not $seen.Contains($key)){
            $seen.Add($key) | Out-Null
            $queue.Enqueue($cand)
          }
        }
      }
    }
  }
}

while($queue.Count -gt 0){
  $cand = $queue.Dequeue()
  $file = $cand[0]; $node = $cand[1]
  $doc = $docs[$file]; $nsmgr = New-NsMgr $doc
  # write node row
  $tns = $doc.DocumentElement.GetAttribute("targetNamespace")
  $kind = $node.Name -replace ".*:", ""
  $anonCount = ($node.SelectNodes(".//xs:complexType[not(@name)] | .//xs:simpleType[not(@name)]",$nsmgr)).Count
  $facetCount = 0
  foreach($r in $node.SelectNodes(".//xs:restriction",$nsmgr)){
    $facetCount += ($r.SelectNodes("xs:*",$nsmgr)).Count
  }
  "{0},{1},{2},{3},{4},{5}" -f $Name,$tns,$kind,$file,$anonCount,$facetCount | Out-File -FilePath $nodesCsv -Append -Encoding utf8

  # enqueue deps
  Add-EdgesAndEnqueue -file $file -node $node -nsmap $null
}

# summary
$lines = @("# Type Dependency Closure", "", "- Root type: `$Name` in `$Namespace`")
$lines += ("- Nodes written: {0}" -f ((Get-Content $nodesCsv | Measure-Object -Line).Lines - 1))
$lines += "## Files that contain visited definitions"
$filesVisited = (Import-Csv $nodesCsv | Select-Object -Skip 1 | Select-Object -ExpandProperty file | Sort-Object -Unique)
foreach($f in $filesVisited){ $lines += "- $f" }
$lines | Out-File -FilePath $summaryMd -Encoding utf8

Write-Host "Wrote:"
Write-Host " - $nodesCsv"
Write-Host " - $edgesCsv"
Write-Host " - $summaryMd"
