# scripts/dmg-settings.py
# dmgbuild settings for LaunchApp.dmg. build.sh passes the paths with -D:
#   app=<path to LaunchApp.app>  background=<path to dmg-background.png>
# Icon positions must match scripts/make-dmg-background.swift.
import os.path

app = defines["app"]  # noqa: F821  (injected by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (920, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    app_name: (300, 200),
    "Applications": (620, 200),
}
