$files = Get-ChildItem .\Root\*.xsd, .\Service\*.xsd -Recurse

foreach ($f in $files) {
  $txt = Get-Content $f.FullName -Raw

  # 1) fix backslashes in schemaLocation
  $txt = $txt -replace 'schemaLocation="\.\.\\Common\\common\.xsd"',
                      'schemaLocation="../Common/common.xsd"'

  # 2) ensure xmlns:tns (same as targetNamespace)
  if ($txt -notmatch 'xmlns:tns=') {
    $txt = $txt -replace '(targetNamespace="[^"]+")',
                        '$1 xmlns:tns="$1"'
    # fix the duplicated attribute value introduced above
    $txt = $txt -replace 'xmlns:tns="targetNamespace="([^"]+)""', 'xmlns:tns="$1"'
  }

  # 3) ensure xmlns:c
  if ($txt -notmatch 'xmlns:c="http://arvest.com/Encore/Common"') {
    $txt = $txt -replace '(elementFormDefault="[^"]+")',
                        '$1 xmlns:c="http://arvest.com/Encore/Common"'
  }

  Set-Content $f.FullName $txt
}

# Report remaining un-prefixed references that you'll need to fix
Select-String -Path .\Root\*.xsd, .\Service\*.xsd `
  -Pattern 'type="(?!xsd:|tns:|c:)[^":]+"|base="(?!xsd:|tns:|c:)[^":]+"' |
  Select-Object Path, LineNumber, Line
