# Réglages de dmgbuild : fenêtre 660×400, Orée à gauche, Applications à droite, image de fond.
# Utilisé par scripts/make_dmg.sh  (dmgbuild -s scripts/dmg-settings.py -D app=Oree.app "Orée" Oree.dmg)
import os

app = defines.get("app", "Oree.app")          # noqa: F821  (« defines » est fourni par dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")   # icône du volume monté
background = "design/dmg-background.tiff"      # chemins relatifs à la racine du dépôt (make_dmg.sh s'y place)

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {app_name: (180, 215), "Applications": (480, 215)}
