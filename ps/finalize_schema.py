#!/usr/bin/env python3
# finalize_schema.py
import argparse
import sys
from lxml import etree as ET

# Define XML Schema Namespace
XS_NS = "http://www.w3.org/2001/XMLSchema"
def q(local): return f"{{{XS_NS}}}{local}"

# Globals we care about for naming
GLOBAL_DEFINITIONS = (q("complexType"), q("simpleType"))
GLOBAL_COMPONENTS = (q("element"), q("complexType"), q("simpleType"))

# Attributes that reference a type name
REF_ATTRS = ("type", "base", "ref")

def get_global_names(root):
    """Returns a set of names for all global elements, complexTypes, and simpleTypes."""
    names = set()
    for child in root:
        if child.tag in GLOBAL_COMPONENTS and "name" in child.attrib:
            names.add(child.attrib["name"])
    return names

def main():
    ap = argparse.ArgumentParser(
        description="Merges an original XSD with a collision-fixed XSD to produce a final, valid schema."
    )
    ap.add_argument("original_xsd", help="Path to the original .xsd with name collisions.")
    ap.add_argument("fixed_xsd", help="Path to the .xsd produced by the fix_collisions.py script.")
    ap.add_argument("output_xsd", help="Path for the final, corrected .xsd output file.")
    args = ap.parse_args()

    # Use a parser that preserves comments and structure
    parser = ET.XMLParser(remove_blank_text=False, recover=True)
    
    # --- Step 1: Analyze both files to find ambiguous names ---
    print("Analyzing schemas to find ambiguous names...")
    original_tree = ET.parse(args.original_xsd, parser)
    original_root = original_tree.getroot()
    original_globals = get_global_names(original_root)

    fixed_tree = ET.parse(args.fixed_xsd, parser)
    fixed_root = fixed_tree.getroot()
    fixed_globals = get_global_names(fixed_root)

    # Find names that were renamed (e.g., "MyType_x2")
    renamed_components = fixed_globals - original_globals
    
    # Infer the original ambiguous names from the renamed ones
    ambiguous_names = set()
    for renamed in renamed_components:
        # Heuristic: assume the original name is the part before "_x" or "_R"
        if "_x" in renamed:
            base_name = renamed.split("_x")[0]
            ambiguous_names.add(base_name)
        elif "_R" in renamed: # for _Rq, _Rs
            base_name = renamed.split("_R")[0]
            ambiguous_names.add(base_name)

    if not ambiguous_names:
        print("No ambiguous names detected. No changes needed.")
        sys.exit(0)

    print(f"Found {len(ambiguous_names)} ambiguous names to fix: {', '.join(sorted(ambiguous_names))}")

    # --- Step 2: Create the new naming plan ---
    # The plan is to rename types with a "Type" suffix
    rename_plan = {name: f"{name}Type" for name in ambiguous_names}

    # --- Step 3: Apply changes to the original schema tree ---
    
    # Part A: Rename the actual type definitions
    print("Renaming global type definitions...")
    for child in original_root:
        if child.tag in GLOBAL_DEFINITIONS and child.attrib.get("name") in rename_plan:
            old_name = child.attrib["name"]
            new_name = rename_plan[old_name]
            print(f"  - Renaming <{child.tag.split('}')[1]}> '{old_name}' -> '{new_name}'")
            child.set("name", new_name)

    # Part B: Update all references throughout the entire document
    print("Updating all references to new type names...")
    update_count = 0
    for elem in original_root.iter('*'):
        for attr_name in REF_ATTRS:
            attr_value = elem.get(attr_name)
            if not attr_value:
                continue

            # Handle potential namespace prefixes (like tns:MyType)
            prefix = ""
            local_name = attr_value
            if ":" in attr_value:
                prefix, local_name = attr_value.split(":", 1)
                prefix += ":"
            
            if local_name in rename_plan:
                new_local_name = rename_plan[local_name]
                new_value = prefix + new_local_name
                elem.set(attr_name, new_value)
                update_count += 1
    
    print(f"Updated {update_count} references.")

    # --- Step 4: Write the final, corrected schema ---
    original_tree.write(
        args.output_xsd,
        pretty_print=True,
        xml_declaration=True,
        encoding="utf-8"
    )
    print(f"\n✅ Successfully created final schema: {args.output_xsd}")

if __name__ == "__main__":
    main()