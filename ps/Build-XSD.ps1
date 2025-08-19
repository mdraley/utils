function New-WrapperXsd {
    param(
        [string]   $Namespace,                     # optional
        [Parameter(Mandatory)] [string[]] $PartFiles,
        [Parameter(Mandatory)] [string]   $OutFile
    )

    $xsNs = "http://www.w3.org/2001/XMLSchema"

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true

    $w = [System.Xml.XmlWriter]::Create($OutFile, $settings)
    try {
        $w.WriteStartDocument()

        # <xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" [targetNamespace=…]>
        $w.WriteStartElement("xs", "schema", $xsNs)
        # explicitly bind the xs prefix so later xs:* elements are valid
        $w.WriteAttributeString("xmlns","xs",$null,$xsNs)

        if ($Namespace -and $Namespace.Trim()) {
            $w.WriteAttributeString("targetNamespace", $Namespace)
            $w.WriteAttributeString("xmlns","tns",$null,$Namespace)
        }

        $w.WriteAttributeString("elementFormDefault", "qualified")
        $w.WriteAttributeString("attributeFormDefault", "unqualified")

        foreach ($p in ($PartFiles | Sort-Object)) {
            # <xs:include schemaLocation="..."/>
            $w.WriteStartElement("xs","include",$xsNs)   # <-- use $xsNs, not $null
            $w.WriteAttributeString("schemaLocation", [IO.Path]::GetFileName($p))
            $w.WriteEndElement()
        }

        $w.WriteEndElement()  # </xs:schema>
        $w.WriteEndDocument()
    } finally {
        $w.Flush()
        $w.Close()
    }
}
