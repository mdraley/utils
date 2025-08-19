# --- helpers ---
function New-SafeName([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "_no_namespace_" }
    return ($s -replace '[^A-Za-z0-9_.-]+','_')
}

# Call xsd.exe with an argument *array* (no cmd.exe) and capture new files
function Invoke-XsdBatch {
    param(
        [Parameter(Mandatory)] [System.Type[]] $ClrTypes,
        [Parameter(Mandatory)] [string] $AsmPath,
        [Parameter(Mandatory)] [string] $OutDir,
        [Parameter(Mandatory)] [int]    $GroupIndex,
        [Parameter(Mandatory)] [int]    $BatchIndex
    )

    if (-not (Test-Path $OutDir)) { throw "OutDir missing: $OutDir" }

    $args = @()
    $args += $AsmPath
    $args += ($ClrTypes | ForEach-Object { "/type:$($_.FullName)" })
    $args += "/out:$OutDir"
    $args += "/nologo"

    Write-Host ("    > xsd.exe (G{0} B{1}) {2} type(s)" -f $GroupIndex, $BatchIndex, $ClrTypes.Count)
    # Remember existing schema*.xsd to compute the delta after run
    $before = Get-ChildItem -Path $OutDir -Filter "schema*.xsd" -Name

    & xsd.exe @args
    $exit = $LASTEXITCODE

    $after   = Get-ChildItem -Path $OutDir -Filter "schema*.xsd" | Sort-Object LastWriteTime
    $newOnes = $after | Where-Object { $before -notcontains $_.Name }

    return @{ Ok = ($exit -eq 0); Exit = $exit; Files = $newOnes }
}

# Rename newly created schema*.xsd to stable names so later batches don't overwrite them
function Rename-NewFiles {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo[]] $Files,
        [Parameter(Mandatory)] [string] $OutDir,
        [Parameter(Mandatory)] [int]    $GroupIndex,
        [Parameter(Mandatory)] [int]    $BatchIndex
    )
    $i = 0
    foreach ($f in $Files) {
        $new = Join-Path $OutDir ("schema-g{0:D3}-b{1:D3}-{2:D2}.xsd" -f $GroupIndex, $BatchIndex, $i)
        Move-Item -Force $f.FullName $new
        $i++
    }
}

# Safe wrapper writer (no empty prefixes; always closes writer)
function New-WrapperXsd {
    param(
        [Parameter(Mandatory)] [string]   $Namespace,  # actual XML namespace (may be empty)
        [Parameter(Mandatory)] [string[]] $PartFiles,  # full paths to schema parts
        [Parameter(Mandatory)] [string]   $OutFile     # wrapper .xsd full path
    )

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true

    $writer = [System.Xml.XmlWriter]::Create($OutFile, $settings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement("xs", "schema", "http://www.w3.org/2001/XMLSchema")

        if ($Namespace -and $Namespace.Trim() -ne "") {
            $writer.WriteAttributeString("targetNamespace", $Namespace)
            # bind default prefix to tns for clarity
            $writer.WriteAttributeString("xmlns", "tns", $null, $Namespace)
        }

        $writer.WriteAttributeString("elementFormDefault", "qualified")
        $writer.WriteAttributeString("attributeFormDefault", "unqualified")

        foreach ($p in $PartFiles | Sort-Object) {
            $writer.WriteStartElement("xs", "include", "http://www.w3.org/2001/XMLSchema")
            $writer.WriteAttributeString("schemaLocation", [IO.Path]::GetFileName($p))
            $writer.WriteEndElement()
        }

        $writer.WriteEndElement()  # </xs:schema>
        $writer.WriteEndDocument()
    }
    finally {
        $writer.Flush()
        $writer.Close()
    }
}

# --- prep and validation ---
if (-not (Test-Path $asmPath)) { throw "Assembly not found: $asmPath" }
New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
Add-Type -AssemblyName System.Xml
$asm = [Reflection.Assembly]::LoadFrom($asmPath)

# Collect XmlSerializer types and their XML namespaces
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

# --- main ---
$groups = $types | Group-Object XmlNs
$gix = 0
foreach ($g in $groups) {
    $gix++
    $ns      = $g.Name
    $safe    = New-SafeName $ns
    $nsDir   = Join-Path $outRoot $safe
    New-Item -ItemType Directory -Force -Path $nsDir | Out-Null

    Write-Host ("[{0}/{1}] XML namespace: {2} -> {3}" -f $gix, $groups.Count, ($ns -ne "" ? $ns : "(no-namespace)"), $nsDir)

    $all   = $g.Group.ClrType
    $start = 0
    $bix   = 0

    while ($start -lt $all.Count) {
        $bix++
        $remaining        = $all.Count - $start
        $currentBatchSize = [Math]::Min($initialBatch, $remaining)
        $curr             = $all[$start..($start + $currentBatchSize - 1)]

        $processed = 0
        while ($curr.Count -gt 0) {
            $res = Invoke-XsdBatch -ClrTypes $curr -AsmPath $asmPath -OutDir $nsDir -GroupIndex $gix -BatchIndex $bix
            if ($res.Ok) {
                if ($res.Files.Count -gt 0) {
                    Rename-NewFiles -Files $res.Files -OutDir $nsDir -GroupIndex $gix -BatchIndex $bix
                }
                $processed = $curr.Count
                break
            } else {
                if ($curr.Count -le 1) {
                    Write-Warning ("xsd.exe failed on single type (Group {0}, Batch {1}). Exit {2}" -f $gix,$bix,$res.Exit)
                    $processed = 1
                    break
                }
                $half = [Math]::Max(1, [Math]::Floor($curr.Count / 2))
                Write-Warning ("    Retrying batch smaller: {0} -> {1}" -f $curr.Count, $half)
                $curr = $curr[0..($half-1)]
            }
        }

        $start += [Math]::Max(1,$processed)
    }

    # Build wrapper for this namespace
    $parts = Get-ChildItem -Path $nsDir -Filter "schema-g*.xsd" | Sort-Object Name
    if ($parts.Count -gt 0) {
        # Read targetNamespace from first part (if present)
        $tns = ""
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.Load($parts[0].FullName)
            $tns = $doc.DocumentElement.GetAttribute("targetNamespace")
        } catch { }

        $wrapper = Join-Path $nsDir ("{0}.xsd" -f $safe)
        New-WrapperXsd -Namespace $tns -PartFiles ($parts.FullName) -OutFile $wrapper
        Write-Host ("  -> Wrapper: {0} (includes {1} parts)" -f $wrapper, $parts.Count)
    } else {
        Write-Warning "  No schema parts found in $nsDir"
    }
}

Write-Host "`nDone. Output root: $outRoot"
