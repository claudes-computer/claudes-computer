#!/bin/bash
# Applies the Mint-style look to a running XFCE session: theme, fonts sized for a TV, one bottom
# taskbar with a menu. Run once per machine by desktop-on.sh (skipped if settings came back from Drive).
PID=$(pgrep -x xfce4-session | head -1); [ -n "$PID" ] || exit 1
export $(tr '\0' '\n' < /proc/$PID/environ | grep -E '^DBUS_SESSION_BUS_ADDRESS=') DISPLAY=:1
q(){ xfconf-query -c "$1" -p "$2" -n -t "$3" -s "$4" 2>/dev/null || xfconf-query -c "$1" -p "$2" -s "$4"; }
# Two workspaces: the person's, and Claude's (claude-window.sh opens Claude's windows there).
xfconf-query -c xfwm4 -p /general/workspace_count -s 2 2>/dev/null
xfconf-query -c xfwm4 -p /general/workspace_names -t string -s "Yours" -t string -s "Claude's" 2>/dev/null || xfconf-query -c xfwm4 -p /general/workspace_names -s "Yours" -s "Claude's"
q xsettings /Net/ThemeName string Mint-Y-Dark-Aqua; q xsettings /Net/IconThemeName string Mint-Y-Aqua
q xsettings /Gtk/FontName string "Ubuntu 10"; q xsettings /Gtk/MonospaceFontName string "Ubuntu Mono 11"
q xsettings /Xft/DPI int 144; q xsettings /Gtk/CursorThemeSize int 48; q xsettings /Gtk/CursorThemeName string Adwaita
q xfwm4 /general/theme string Mint-Y-Dark-Aqua; q xfwm4 /general/title_font string "Ubuntu Medium 10"
q xfce4-desktop /desktop-icons/icon-size uint 72
# Window tiling from the arrow keys (the built-in shortcuts use the number pad, which many keyboards lack):
# Super+Left/Right = half screen, Super+Ctrl+Left/Right = top quarters, Super+Shift+Left/Right = bottom quarters.
for kv in "<Super>Left tile_left_key" "<Super>Right tile_right_key" "<Super>Up maximize_window_key" "<Super>Down hide_window_key" \
  "<Super><Control>Left tile_up_left_key" "<Super><Control>Right tile_up_right_key" \
  "<Super><Shift>Left tile_down_left_key" "<Super><Shift>Right tile_down_right_key"; do
  set -- $kv; q xfce4-keyboard-shortcuts "/xfwm4/custom/$1" string "$2"
done
# Ctrl+Shift+Esc opens the task manager, as on Windows.
q xfce4-keyboard-shortcuts "/commands/custom/<Primary><Shift>Escape" string xfce4-taskmanager
q xfwm4 /general/tile_on_move bool true
xfce4-panel --quit 2>/dev/null; sleep 1
xfconf-query -c xfce4-panel -p /panels -r -R 2>/dev/null; xfconf-query -c xfce4-panel -p /plugins -r -R 2>/dev/null
xfconf-query -c xfce4-panel -p /panels -n -t int -s 1 -a
P=/panels/panel-1
q xfce4-panel $P/position string "p=8;x=960;y=1065"; q xfce4-panel $P/length uint 100; q xfce4-panel $P/position-locked bool true
q xfce4-panel $P/size uint 48; q xfce4-panel $P/icon-size uint 26; q xfce4-panel $P/mode uint 0
xfconf-query -c xfce4-panel -p $P/plugin-ids -n $(for i in 1 2 3 8 4 5 6 7; do printf -- "-t int -s %s " $i; done) -a
q xfce4-panel /plugins/plugin-1 string whiskermenu
q xfce4-panel /plugins/plugin-2 string tasklist; q xfce4-panel /plugins/plugin-2/flat-buttons bool true
q xfce4-panel /plugins/plugin-2/show-handle bool false; q xfce4-panel /plugins/plugin-2/show-labels bool true
q xfce4-panel /plugins/plugin-3 string separator; q xfce4-panel /plugins/plugin-3/expand bool true; q xfce4-panel /plugins/plugin-3/style uint 0
q xfce4-panel /plugins/plugin-8 string pager; q xfce4-panel /plugins/plugin-8/miniature-view bool false
q xfce4-panel /plugins/plugin-8/rows uint 1   # [Yours | Claude's]: flip between the two workspaces
q xfce4-panel /plugins/plugin-4 string systray
q xfce4-panel /plugins/plugin-5 string pulseaudio
q xfce4-panel /plugins/plugin-6 string notification-plugin
q xfce4-panel /plugins/plugin-7 string clock; q xfce4-panel /plugins/plugin-7/digital-layout uint 3
q xfce4-panel /plugins/plugin-7/digital-time-format string "%-I:%M %p"
q xfce4-panel /plugins/plugin-7/timezone string "${CCRD_TZ:-}"
mkdir -p $HOME/.config/xfce4/panel
printf 'button-title=Menu\nbutton-icon=start-here\nshow-button-title=true\nshow-button-icon=true\nfavorites=chrome.desktop,thunar.desktop,xfce4-terminal.desktop,org.xfce.mousepad.desktop,org.gnome.Calculator.desktop\n' \
  > $HOME/.config/xfce4/panel/whiskermenu-1.rc
(setsid xfce4-panel >/tmp/panel.log 2>&1 &); sleep 4
# The virtual screen is "screen"; the stream adds its own, "selkies-primary", once it starts (often after this runs).
for mon in $( (xfconf-query -c xfce4-desktop -l; printf '%s\n' /backdrop/screen0/monitorscreen/ /backdrop/screen0/monitorselkies-primary/) \
    | grep -oE '/backdrop/screen0/monitor[^/]+' | sort -u); do b=$mon/workspace0
  # Background: the Claude's Computer logo on dark grey #1e1e1e (cloud/wallpaper.png).
  q xfce4-desktop $b/image-style int 4; q xfce4-desktop $b/last-image string /opt/ccrd/wallpaper.png
  q xfce4-desktop $b/color-style int 0
  for k in "rgba1 0.118 0.118 0.118"; do set -- $k
    xfconf-query -c xfce4-desktop -p $b/$1 -n -t double -t double -t double -t double -s $2 -s $3 -s $4 -s 1 2>/dev/null \
      || xfconf-query -c xfce4-desktop -p $b/$1 -t double -t double -t double -t double -s $2 -s $3 -s $4 -s 1
  done
done
xfdesktop --reload >/dev/null 2>&1
# XFCE only runs desktop launchers the user has trusted: newer versions check a checksum, older ones a flag.
gio set $HOME/Desktop/chrome.desktop metadata::trusted true 2>/dev/null
gio set -t string $HOME/Desktop/chrome.desktop metadata::xfce-exe-checksum "$(sha256sum $HOME/Desktop/chrome.desktop | cut -d' ' -f1)" 2>/dev/null
xdg-mime default chrome.desktop x-scheme-handler/http x-scheme-handler/https text/html 2>/dev/null
# Sensible default apps: pictures, PDFs and text open in their own viewers, not the browser.
xdg-mime default org.xfce.ristretto.desktop image/png image/jpeg image/gif image/webp image/bmp 2>/dev/null
xdg-mime default org.gnome.Evince.desktop application/pdf 2>/dev/null
xdg-mime default org.xfce.mousepad.desktop text/plain 2>/dev/null
