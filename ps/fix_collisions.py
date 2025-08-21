#!/usr/bin/env python3
# fix_collisions.py
import argparse, sys
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
REF_ATTRS = ("type", "base", "ref")

def localname(tag): return tag.split('}',1)[1] if '}' in tag else tag
def load_tree(path):
    if HAVE_LXML:
        return ET.parse(path, ET.XMLParser(remove_blank_text=False))
    return ET.parse(path)

def iter_all(e):
    yield e
    for c in list(e):
        yield from iter_all(c)

def text_blob(elem):
    try:
        return ET.tostring(elem, encoding="unicode")
    except Exception:
        return ""

def guess_affinity(elem):
    """
    Try to guess whether a duplicate looks like a request (Rq) or response (Rs).
    Signals we count:
      - child/@name, @type, @base containing 'Rq' or 'Rs'
      - inner text with 'request'/'response'
      - attributes like 'RqEchoFlag', 'EchoFlag'
    """
    blob = text_blob(elem).lower()
    rq = blob.count("request") + blob.count("rqecho") + blob.count(">rq<")
    rs = blob.count("response") + blob.count("echoflag") + blob.count(">rs<")

    for n in elem.iter():
        for attr in ("name","type","base"):
            v = (n.get(attr) or "").lower()
            if "rq" in v: rq += 1
            if "rs" in v: rs += 1

    if rq >= rs + 2: return "_Rq"
    if rs >= rq + 2: return "_Rs"
    # very close? prefer explicit tokens
    if rq > rs and rq >= 2: return "_Rq"
    if rs > rq and rs >= 2: return "_Rs"
    return None

def main():
    ap = argparse.ArgumentParser(description="Fix duplicate global names; rename with _Rq/_Rs when possible.")
    ap.add_argument("input", help="Input .xsd")
    ap.add_argument("-o","--output", required=True, help="Output .xsd")
    ap.add_argument("--fallback-suffix", default="_x{n}", help="Used if Rq/Rs not detected (default _x{n})")
    ap.add_argument("--dry-run", action="store_true", help="Only report actions; do not write")
    args = ap.parse_args()

    tree = load_tree(args.input)
    root = tree.getroot()
    if root.tag != q("schema"):
        print("Error: root is not xs:schema", file=sys.stderr); sys.exit(2)

    # 1) collect global decls by name (preserve order)
    order = []
    by_name = defaultdict(list)
    for ch in root:
        if ch.tag in GLOBAL_KINDS and "name" in ch.attrib:
            order.append(ch)
            by_name[ch.attrib["name"]].append(ch)

    # 2) build rename plan
    rename_plan = {}                # node-id -> (old, new)
    canonical_name = {}             # old -> old (explicit for clarity)
    chosen_names = set(by_name.keys())

    for name, nodes in by_name.items():
        if len(nodes) <= 1:
            continue
        canonical_name[name] = name
        # keep first unchanged; rename others
        for i, node in enumerate(nodes, start=1):
            if i == 1: continue
            # try heuristic
            hx = guess_affinity(node)
            base = name + (hx if hx else args.fallback_suffix.format(n=i))
            new_name = base
            bump = i
            while new_name in chosen_names:
                bump += 1
                new_name = name + args.fallback_suffix.format(n=bump)
            chosen_names.add(new_name)
            rename_plan[id(node)] = (name, new_name)

    if not rename_plan:
        print("✅ No duplicates to fix.")
        return

    print("Planned renames:")
    for ch in order:
        nid = id(ch)
        if nid in rename_plan:
            old, new = rename_plan[nid]
            ln = getattr(ch, "sourceline", None) if HAVE_LXML else None
            print(f"  - {localname(ch.tag)} {old} -> {new}" + (f" (line {ln})" if ln else ""))

    # 3) apply @name changes
    for ch in order:
        nid = id(ch)
        if nid in rename_plan:
            _, new = rename_plan[nid]
            ch.set("name", new)

    # 4) update references globally to canonical names (the unchanged first one)
    changed_groups = {old for (_, (old, _)) in rename_plan.items()}
    updates = 0
    for e in iter_all(root):
        for a in REF_ATTRS:
            v = e.get(a)
            if not v: continue
            if ":" in v:
                pfx, lname = v.split(":",1); prefix = pfx + ":"
            else:
                lname = v; prefix = ""
            if lname in changed_groups:
                canon = canonical_name.get(lname, lname)
                nv = prefix + canon
                if nv != v:
                    e.set(a, nv); updates += 1

    print(f"Updated {updates} QName reference(s) to canonical declarations.")

    if args.dry_run:
        print("--dry-run: not writing output.")
        return

    if HAVE_LXML:
        tree.write(args.output, pretty_print=True, xml_declaration=True, encoding="utf-8")
    else:
        tree.write(args.output, xml_declaration=True, encoding="utf-8")
    print(f"✅ Wrote cleaned schema -> {args.output}")

if __name__ == "__main__":
    main()
