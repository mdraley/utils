# 1) Ensure targetNamespace + xmlns:tns are present (add if missing)
Get-ChildItem -Filter *.xsd | ForEach-Object {
  $p = $_.FullName
  $txt = Get-Content $p -Raw

  # normalize http/https once; set the one you chose:
  $ns = 'http://www.fiserv.com/cbs'   # or 'https://www.fiserv.com/cbs'

  # ensure targetNamespace
  if ($txt -notmatch 'targetNamespace="https?://www\.fiserv\.com/cbs"') {
    $txt = $txt -replace '<xs:schema', "<xs:schema targetNamespace=""$ns"""
  } else {
    $txt = $txt -replace 'targetNamespace="https?://www\.fiserv\.com/cbs"', "targetNamespace=""$ns"""
  }

  # ensure xmlns:tns
  if ($txt -notmatch 'xmlns:tns="https?://www\.fiserv\.com/cbs"') {
    $txt = $txt -replace '<xs:schema', "<xs:schema xmlns:tns=""$ns"""
  } else {
    $txt = $txt -replace 'xmlns:tns="https?://www\.fiserv\.com/cbs"', "xmlns:tns=""$ns"""
  }

  # 2) Replace any qN: prefix with tns:
  $txt = $txt -replace 'q\d+:', 'tns:'

  Set-Content -Path $p -Value $txt -Encoding UTF8
}
