#!/usr/bin/env python3
"""Génère Resources/THIRD_PARTY_NOTICES.md : les licences et mentions de tout ce qu'Orée embarque ou télécharge.

  python3 scripts/make_notices.py        # puis relancer ./build_app.sh : le fichier est copié dans l'app (À propos › Licences)
Les crates Rust viennent de `cargo metadata` sur Rust/adblock_bridge (sources déjà téléchargées par cargo) ; rien n'est inventé : une crate sans fichier de licence est signalée.
"""
import glob, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "THIRD_PARTY_NOTICES.md")
LIC = os.path.join(ROOT, "Resources", "Licenses")

def read(path): return open(path, encoding="utf-8", errors="replace").read().strip()

def crates():
    meta = json.loads(subprocess.run(["cargo", "metadata", "--format-version", "1", "--offline"], cwd=os.path.join(ROOT, "Rust", "adblock_bridge"), capture_output=True, text=True, check=True).stdout)
    root = meta["resolve"]["root"]
    for p in sorted(meta["packages"], key=lambda p: p["name"]):
        if p["id"] == root: continue
        yield p

def notices(package):
    """Les lignes « Copyright … » des fichiers de licence de la crate."""
    folder = os.path.dirname(package["manifest_path"])
    found, missing = [], True
    for path in sorted(glob.glob(os.path.join(folder, "[Ll][Ii][Cc][Ee][Nn][Ss][Ee]*")) + glob.glob(os.path.join(folder, "[Cc][Oo][Pp][Yy][Ii][Nn][Gg]*")) + glob.glob(os.path.join(folder, "[Nn][Oo][Tt][Ii][Cc][Ee]*"))):
        if os.path.isfile(path):
            missing = False
            for line in read(path).splitlines():
                if re.match(r"\s*(copyright|©|\(c\))", line, re.I) and line.strip() not in found: found.append(line.strip())
    return found[:3], missing

def canonical(spdx_fragment, names):
    """Le texte d'une licence, pris dans le fichier d'une crate qui l'utilise."""
    for package in crates():
        if spdx_fragment in (package.get("license") or ""):
            folder = os.path.dirname(package["manifest_path"])
            for name in names:
                path = os.path.join(folder, name)
                if os.path.isfile(path): return read(path)
    return None

lines = ["# Licences et mentions", "",
         "Orée est un navigateur construit sur WebKit, le moteur du système macOS (fourni par Apple, non redistribué ici). Il embarque ou télécharge ce qui suit. Généré par `scripts/make_notices.py`.", ""]

lines += ["## Bibliothèque Swift", "", "### GRDB.swift 6.29.3 — licence MIT", "https://github.com/groue/GRDB.swift", "", "```", read(os.path.join(LIC, "MIT-GRDB.txt")), "```", ""]

lines += ["## Polices embarquées", "",
          "### Instrument Sans — SIL Open Font License 1.1", "https://github.com/Instrument/instrument-sans", "", "```", read(os.path.join(LIC, "OFL-InstrumentSans.txt")), "```", "",
          "### Instrument Serif — SIL Open Font License 1.1", "https://github.com/Instrument/instrument-serif", "", "```", read(os.path.join(LIC, "OFL-InstrumentSerif.txt")), "```", ""]

lines += ["## Règles de nettoyage des liens (ClearURLs) — LGPL-3.0", "",
          "Orée embarque, sans modification, une copie des règles de https://github.com/ClearURLs/Rules (données JSON). Une copie plus récente téléchargée dans le dossier Application Support d'Orée la remplace : vous pouvez donc substituer ces règles par les vôtres. Texte de la licence :", "",
          "```", read(os.path.join(LIC, "LGPL-3.0-ClearURLs.txt")), "```", ""]

lines += ["## Téléchargés au lancement, non embarqués", "",
          "- **EasyList et EasyPrivacy** (https://easylist.to) : listes de filtres publiées sous double licence GPLv3 / CC BY-SA 3.0, téléchargées depuis easylist.to et appliquées par le moteur de blocage ; Orée n'en redistribue aucune copie.",
          "- **Google Safe Browsing** : utilisé seulement si vous saisissez votre propre clé d'API dans les Réglages ; son usage relève des conditions de Google (https://developers.google.com/safe-browsing/terms), qui limitent l'API v4 à un usage non commercial.", ""]

lines += ["## Bibliothèques Rust (blocage de publicités et compression)", "",
          "La compression utilise la bibliothèque C zstd (https://github.com/facebook/zstd), employée ici sous sa licence BSD-3-Clause (elle est aussi proposée en GPL-2.0). Le blocage de publicités utilise le moteur `adblock-rust` de Brave (MPL-2.0) : https://github.com/brave/adblock-rust. Les crates MPL-2.0 ci-dessous sont utilisées **sans modification** ; leur code source est disponible à l'adresse indiquée pour chacune.", "",
          "| Crate | Version | Licence | Source |", "|---|---|---|---|"]
details = []
for p in crates():
    lic = (p.get("license") or "non indiquée").replace("|", "/")
    if "r-efi" == p["name"]: lic += " (choisie : MIT ; non utilisée sur macOS)"
    lines.append(f"| {p['name']} | {p['version']} | {lic} | {p.get('repository') or p.get('homepage') or '—'} |")
    found, missing = notices(p)
    details.append((p["name"], found, missing))
lines += ["", "### Mentions de droits d'auteur", ""]
for name, found, missing in details:
    if found: lines.append(f"- **{name}** : " + " ; ".join(found))
    elif missing: lines.append(f"- **{name}** : aucun fichier de licence dans la crate (licence déclarée ci-dessus).")
lines += ["", "### Textes des licences", ""]
texts = {
    "MIT": ["LICENSE-MIT", "LICENSE", "LICENSE.md"],
    "Apache-2.0": ["LICENSE-APACHE", "LICENSE-APACHE.md"],
    "MPL-2.0": ["LICENSE", "LICENSE.md", "LICENSE.txt"],
    "BSD-3-Clause": ["LICENSE", "LICENSE.md"],
    "Unicode-3.0": ["LICENSE-UNICODE", "LICENSE"],
}
for spdx, names in texts.items():
    body = canonical(spdx, names)
    if body and spdx in ("MIT", "BSD-3-Clause"):   # le texte vient d'une crate : on n'attribue pas SON copyright à toutes les autres
        body = re.sub(r"(?im)^\s*copyright.*$", "Copyright (c) <année> <titulaire> (les titulaires de chaque bibliothèque sont indiqués plus haut)", body)
    lines += [f"#### {spdx}", "", "```", body or f"(texte à reprendre depuis https://spdx.org/licenses/{spdx}.html)", "```", ""]
open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(f"{OUT} : {os.path.getsize(OUT) // 1024} Ko, {len(details)} crates, sans fichier de licence : {[n for n, f, m in details if m]}")
