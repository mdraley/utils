# PowerShell XSD Utilities

This folder contains two PowerShell scripts you can run on Windows (no Python required):

1. **Scan-XsdRepo.ps1** — scan a whole XSD repo to find:
   - Every `<xs:import>` / `<xs:include>`
   - All global definitions (complexType, simpleType, element, attributeGroup, group)
   - Cross-file type usage (where a type is referenced vs where it is defined)
   - A summary of most-imported namespaces and top reused types

2. **Get-XsdTypeClosure.ps1** — for a single type (namespace + local name), compute the full dependency closure:
   - Base types via restriction/extension/list/union
   - Element/attribute type refs
   - Group / attributeGroup refs
   - Facet counts on restrictions
   - Outputs a node/edge CSV and a summary

## How to run

Open PowerShell in this folder and run:

```powershell
# 1) Repo scan
.\Scan-XsdRepo.ps1 -Root "C:\path\to\all\xsds" -OutDir ".\xsd_scan_out"

# 2) Type closure
.\Get-XsdTypeClosure.ps1 -Root "C:\path\to\all\xsds" `
  -Namespace "http://schemas.company.com/common" `
  -Name "RqUIDType" `
  -OutDir ".\type_closure_out"
```

Outputs:
- `xsd_scan_out\imports.csv`, `definitions.csv`, `usage.csv`, `SUMMARY.md`
- `type_closure_out\nodes.csv`, `edges.csv`, `SUMMARY.md`

> Tip: Use Excel/Power BI to pivot `usage.csv` and find which `(ns,type)` pairs are reused across many files and which file defines them (see `def_files` column). Those are ideal candidates to move to `common-types.xsd`.

## Notes
- Scripts use .NET's XML APIs and should work on Windows PowerShell 5.1 and PowerShell 7+.
- They’re fast heuristics and do not fully validate XSDs; they’re designed to guide refactoring and episode setup.
- If your schemas use exotic constructs, we can extend the selectors easily.
