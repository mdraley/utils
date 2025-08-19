New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
Add-Type -AssemblyName System.Xml
$asm = [Reflection.Assembly]::LoadFrom($asmPath)

# Collect XmlSerializer types + their XML namespaces
$types = $asm.GetTypes() | Where-Object {
  $_.IsPublic -and (
    $_.GetCustomAttributes([System.Xml.Serialization.XmlTypeAttribute], $true).Count -gt 0 -or
    $_.GetCustomAttributes([System.Xml.Serialization.XmlRootAttribute], $true).Count -gt 0)
} | ForEach-Object {
  $xt = $_.GetCustomAttributes([System.Xml.Serialization.XmlTypeAttribute], $true) | Select-Object -First 1
  $xr = $_.GetCustomAttributes([System.Xml.Serialization.XmlRootAttribute], $true) | Select-Object -First 1
  [PSCustomObject]@{
    ClrType = $_
    XmlNs   = if ($xt -and $xt.Namespace) { $xt.Namespace }
             elseif ($xr -and $xr.Namespace) { $xr.Namespace }
             else { "(no-namespace)" }
  }
}

if ($types.Count -eq 0) { throw "No XmlSerializer types found in $asmPath." }

$groups = $types | Group-Object XmlNs
$gix = 0
foreach ($g in $groups) {
  $gix++
  $ns = $g.Name
  $safe = ($ns -replace '[^\w\.]+','_')
  $nsDir = Join-Path $outRoot $safe
  New-Item -ItemType Directory -Force -Path $nsDir | Out-Null
  Write-Host "[$gix/$($groups.Count)] XML namespace: $ns -> $nsDir"

  # Split into batches
  $count = $g.Group.Count
  $bix = 0
  for ($i = 0; $i -lt $count; $i += $batchSize) {
    $bix++
    $batch = $g.Group[$i..([Math]::Min($i+$batchSize-1,$count-1))]
    $typeArgs = ($batch | ForEach-Object { "/type:$($_.ClrType.FullName)" }) -join ' '
    $cmd = "`"$xsdExe`" `"$asmPath`" $typeArgs /out:`"$nsDir`" /nologo"
    Write-Host "  - Batch $bix: $($batch.Count) types"
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { Write-Warning "xsd.exe exit $($proc.ExitCode) on batch $bix" }

    # Rename outputs from this batch so the next batch won't overwrite them
    $generated = Get-ChildItem -Path $nsDir -Filter "schema*.xsd" | Sort-Object LastWriteTime
    $fixIndex = 0
    foreach ($f in $generated) {
      # Only rename files that were touched in the last few seconds (this batch)
      if ((Get-Date) - $f.LastWriteTime -lt [TimeSpan]::FromSeconds(5)) {
        $new = Join-Path $nsDir ("schema-b{0:D3}-{1:D2}.xsd" -f $bix,$fixIndex)
        Move-Item -Force $f.FullName $new
        $fixIndex++
      }
    }
  }

  # Create wrapper XSD that includes all batch files
  $parts = Get-ChildItem -Path $nsDir -Filter "schema-b*.xsd" | Sort-Object Name
  if ($parts.Count -gt 0) {
    # read targetNamespace from the first part
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($parts[0].FullName)
    $tns = $doc.DocumentElement.GetAttribute("targetNamespace")

    $wrapper = Join-Path $nsDir ($safe + ".xsd")
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $w = [System.Xml.XmlWriter]::Create($wrapper, $settings)
    $w.WriteStartElement("xs","schema","http://www.w3.org/2001/XMLSchema")
    if ($tns) {
      $w.WriteAttributeString("targetNamespace", $tns)
      $w.WriteAttributeString("xmlns","tns",$null,$tns)
    }
    $w.WriteAttributeString("elementFormDefault","qualified")
    $w.WriteAttributeString("attributeFormDefault","unqualified")

    foreach ($p in $parts) {
      $w.WriteStartElement("xs","include",$null)
      $w.WriteAttributeString("schemaLocation", $p.Name)
      $w.WriteEndElement()
    }

    $w.WriteEndElement(); $w.Flush(); $w.Close()
    Write-Host "  -> Wrote wrapper: $wrapper (includes $($parts.Count) parts)"
  } else {
    Write-Warning "No schema-b*.xsd parts found in $nsDir"
  }
}

Write-Host "`nDone. Output root: $outRoot"