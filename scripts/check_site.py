#!/usr/bin/env python3
"""Vérifie le site statique : liens relatifs, ancres internes et fichiers référencés."""
import re, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent / "website"
html = (root / "index.html").read_text(encoding="utf-8")
ids = set(re.findall(r'\bid="([^"]+)"', html))
errors = []
for href in re.findall(r'(?:href|src)="([^"]+)"', html):
    if href.startswith(("http://", "https://", "mailto:")):
        continue
    if href.startswith("#"):
        if href[1:] and href[1:] not in ids:
            errors.append(f"ancre manquante : {href}")
    elif href.startswith("#") is False and not (root / href.split("#")[0]).exists():
        errors.append(f"fichier manquant : {href}")
for ref in re.findall(r'url\("([^")]+)"\)', (root / "styles.css").read_text(encoding="utf-8")):
    if not ref.startswith(("http", "data:")) and not (root / ref).exists():
        errors.append(f"fichier CSS manquant : {ref}")
for m in re.findall(r'<use href="#([^"]+)"', html):
    if m not in ids:
        errors.append(f"symbole SVG manquant : #{m}")
if errors:
    print("\n".join(errors)); sys.exit(1)
print("Site OK")
