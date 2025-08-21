#!/usr/bin/env python3
# find_collisions.py
import argparse, json, sys
from collections import defaultdict
try:
    from lxml import etree as ET
    HAVE_LXML = True
except Exception:
    import xml.etree.ElementTree as ET
    HAVE_LXML = False

XS_NS = "http://www.w3.org/2001/XMLSchema"
def q(local): return f"{{{XS_NS}}}{local}"
GLOBAL_KINDS = (q("element"), q("complexType"), q("simpleType"))

def localname(tag): return tag.split('}',1)[1] if '}' in tag else tag
def load_tree(path):
    if HAVE_LXML:
        return ET.parse(path, ET.XMLParser(remove_blank_text=False))
    return ET.parse(path)

def main():
    ap = argparse.ArgumentParser(description="Find duplicate global XSD names.")
    ap.add_argument("xsd", help="Path to .xsd")
    ap.add_argument("--json", help="Optional JSON output")
    args = ap.parse_args()

    tree = load_tree(args.xsd)
    root = tree.getroot()
    if root.tag != q("schema"):
        print("Error: root is not xs:schema", file=sys.stderr); sys.exit(2)

    by_name = defaultdict(list)
    for ch in root:
        if ch.tag in GLOBAL_KINDS and "name" in ch.attrib:
            by_name[ch.attrib["name"]].append({
                "kind": localname(ch.tag),
                "line": getattr(ch, "sourceline", None) if HAVE_LXML else None
            })
    dupes = {k:v for k,v in by_name.items() if len(v) > 1}
    if not dupes:
        print("✅ No duplicate global names found.")
    else:
        print(f"⚠️  {len(dupes)} duplicate name group(s):")
        for name, items in sorted(dupes.items()):
            locs = ", ".join(f"{it['kind']}{':' + str(it['line']) if it['line'] else ''}" for it in items)
            print(f"  - {name}  ({len(items)}): {locs}")
    if args.json:
        import json
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(dupes, f, indent=2)
        print(f"Wrote JSON -> {args.json}")

if __name__ == "__main__":
    main()
