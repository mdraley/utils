# Build-XSD-Auto.ps1  (requires xsd.exe on PATH)

$asmPath      = "C:\path\to\Arvest.HostComm.dll"
$outRoot      = "C:\code\encore\schema\hostcomm-xsd"
$initialBatch = 40

$xsdExe = "xsd.exe"

function New-SafeName([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "_no_namespace_" }
    return ($s -replace '[^A-Za-z0-9_.-]+','_')
}

function Invoke-XsdBatch {
    param(
        [System.Type[]] $ClrTypes,
        [string] $AsmPath,
        [string] $OutDir,
        [int] $GroupIndex,
        [int] $BatchIndex
    )
    $typeArgs = ($ClrTypes | ForEach-Object { "/type:$($_.FullName)" }) -join ' '
    $before   = Get-ChildItem -Path $OutDir -Filter "schema*.xsd" -Name
    $cmd      = "`"$xsdExe`" `"$AsmPath`" $typeArgs /out:`"$OutDir`" /nologo"
    $proc     = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -Wait -PassThru -NoNewWindow
    $exit     = $proc.ExitCode
    $after    = Get-ChildItem -Path $OutDir -Filter "schema*.xsd" | Sort-Object Name
    $newOnes  = $after | Where-Object { $before -notcontains $_.Name }
    return @{ Ok = ($exit -eq 0); Exit = $exit; Files = $newOnes }
}

function Rename-NewFiles {
    param(
        [System.IO.FileInfo[]] $Files,
        [string] $OutDir,
        [int] $GroupIndex,
        [int] $BatchIndex
    )
    $i = 0
    foreach ($f in $Files) {
        $new = Join-Path $OutDir ("schema-g{0:D3}-b{1:D3}-{2:D2}.xsd" -f $GroupIndex, $BatchIndex, $i)
        Move-Item -Force $f.FullName $new
        $i++
    }
}

New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
Add-Type -AssemblyName System.Xml
$asm = [Reflection.Assembly]::LoadFrom($asmPath)

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
                  else { "" }
    }
}

if ($types.Count -eq 0) { throw "No XmlSerializer types found in $asmPath." }

$groups = $types | Group-Object XmlNs
$gix = 0
foreach ($g in $groups) {
    $gix++
    $ns    = $g.Name
    $safe  = New-SafeName $ns
    $nsDir = Join-Path $outRoot $safe
    New-Item -ItemType Directory -Force -Path $nsDir | Out-Null

    $all   = $g.Group.ClrType
    $start = 0
    $bix   = 0

    while ($start -lt $all.Count) {
        $bix++
        $remaining          = $all.Count - $start
        $currentBatchSize   = [Math]::Min($initialBatch, $remaining)
        $window             = $all[$start..($start + $currentBatchSize - 1)]
        $ok                 = $false
        $curr               = $window

        while (-not $ok) {
            $res = Invoke-XsdBatch -ClrTypes $curr -AsmPath $asmPath -OutDir $nsDir -GroupIndex $gix -BatchIndex $bix
            if ($res.Ok) {
                Rename-NewFiles -Files $res.Files -OutDir $nsDir -GroupIndex $gix -BatchIndex $bix
                $ok = $true
            } else {
                if ($curr.Count -le 1) {
                    Write-Warning ("xsd.exe failed on single type (G{0} B{1}) exit {2}" -f $gix, $bix, $res.Exit)
                    $ok = $true
                } else {
                    $half = [Math]::Max(1, [Math]::Floor($curr.Count / 2))
                    $curr = $curr[0..($half - 1)]
                }
            }
        }

        $start += $curr.Count
    }

    $parts = Get-ChildItem -Path $nsDir -Filter "schema-g*.xsd" | Sort-Object Name
    if ($parts.Count -gt 0) {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($parts[0].FullName)
        $tns = $doc.DocumentElement.GetAttribute("targetNamespace")

        $wrapper  = Join-Path $nsDir ($safe + ".xsd")
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
        $w.WriteEndElement()
        $w.Flush()
        $w.Close()
    }
}

Write-Host "Done. Output root: $outRoot"
