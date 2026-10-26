#!/bin/bash
# =============================================================================
# uninstall.sh – entfernt Autostart, Programm und (optional) Daten von MailStrip
# =============================================================================
# launchd-Domäne des angemeldeten Benutzers.
GUI="gui/$(id -u)"
# Hier liegen Programm, Skripte, config.json und Managerliste.
APP_DIR="$HOME/Library/Application Support/MailStrip"

# Dienste stoppen und Autostart-Dateien löschen.
for L in com.andreasbrolund.mailstrip com.andreasbrolund.mailstrip.checker; do
  launchctl bootout "$GUI/$L" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$L.plist"
done
echo "Autostart entfernt."

# Daten nur auf Nachfrage löschen (enthält deine config.json).
read -r -p "Auch Programm, Config und Logs löschen? [j/N] " a
if [ "$a" = "j" ]; then
  rm -rf "$APP_DIR" "$HOME/Library/Logs/MailStrip"
  echo "Gelöscht."
fi
