$types = @('StatusType','AcctBasicType','BankIdType','StatusTypeType')  # add more as needed

$commonXsd = "C:\code\encore\schema\Common\common.xsd"
[xml]$doc = New-Object System.Xml.XmlDocument
$doc.PreserveWhitespace = $true
$doc.Load($commonXsd)

# ns mgr (for XPath on XSD)
$nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$nsm.AddNamespace('xsd','http://www.w3.org/2001/XMLSchema')

# ensure prefix declaration
$schema = $doc.DocumentElement
if (-not $schema.GetAttribute('xmlns:c')) {
  $schema.SetAttribute('xmlns:c','http://arvest.com/Encore/Common') | Out-Null
}

# Prefix internal references: @type and @base
foreach ($t in $types) {
  # any element/attribute with @type="T" or @type="*:T"
  $nodes = $doc.SelectNodes("//@type", $nsm)
  foreach ($a in $nodes) {
    $val = $a.Value
    $local = ($val -split ':')[-1]
    if ($local -eq $t) { $a.Value = "c:$t" }
  }
  # any extension/restriction with @base="T" or @base="*:T"
  $nodes2 = $doc.SelectNodes("//@base", $nsm)
  foreach ($a in $nodes2) {
    $val = $a.Value
    $local = ($val -split ':')[-1]
    if ($local -eq $t) { $a.Value = "c:$t" }
  }
}

$doc.Save($commonXsd)
Write-Host "common.xsd updated with c: prefixes for moved types."