function Invoke-XsdBatch {
    param(
        [Parameter(Mandatory)] [System.Type[]] $ClrTypes,
        [Parameter(Mandatory)] [string] $AsmPath,
        [Parameter(Mandatory)] [string] $OutDir,
        [Parameter(Mandatory)] [int] $GroupIndex,
        [Parameter(Mandatory)] [int] $BatchIndex
    )

    if (-not (Test-Path $OutDir)) { throw "OutDir missing: $OutDir" }

    # Build a *list* of arguments, not a single string
    $args = @()
    $args += $AsmPath
    $args += ($ClrTypes | ForEach-Object { "/type:$($_.FullName)" })   # PS will quote as needed
    $args += "/out:$OutDir"
    $args += "/nologo"

    Write-Host ("    > xsd.exe (G{0} B{1}) {2} type(s)" -f $GroupIndex, $BatchIndex, $ClrTypes.Count)
    Write-Host ("      args: {0}" -f ($args -join ' ')) -ForegroundColor DarkCyan

    # Call xsd.exe directly; no cmd.exe
    & $xsdExe @args
    $exit = $LASTEXITCODE

    # Find just the new schema*.xsd files
    $after   = Get-ChildItem -Path $OutDir -Filter "schema*.xsd" | Sort-Object LastWriteTime -Descending
    # Heuristic: anything created/updated in the last 5 seconds belongs to this run
    $cutoff  = (Get-Date).AddSeconds(-5)
    $newOnes = $after | Where-Object { $_.LastWriteTime -ge $cutoff }

    return @{ Ok = ($exit -eq 0); Exit = $exit; Files = $newOnes }
}
