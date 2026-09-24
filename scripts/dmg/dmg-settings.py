# dmgbuild settings for the Transcripts disk image. Read by release.sh:
#
#   dmgbuild -s scripts/dmg/dmg-settings.py -D app=path/to/Transcripts.app \
#     "Transcripts" dist/Transcripts-1.2.0.dmg
#
# dmgbuild writes the Finder layout (.DS_Store) directly instead of scripting
# Finder, so it works on a CI runner with nobody logged in, where the
# AppleScript-driven tools fail or hang.
import os.path

app = defines.get("app", "Transcripts.app")  # noqa: F821 — injected by dmgbuild
# Relative to the repository root, where release.sh runs dmgbuild; dmgbuild
# does not tell a settings file where it lives.
background = defines.get("background", "scripts/dmg/background.tiff")  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

# Must match APP_X / APPS_X / ICON_Y in make-dmg-background.py.
icon_locations = {os.path.basename(app): (180, 190), "Applications": (480, 190)}
window_rect = ((200, 160), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
arrange_by = None
hide_extension = [os.path.basename(app)]
