#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "AI PropHunt — Configurar ejecucion automatica (BetterPlace)"
echo ""
echo "El email de BetterPlace llega ~7:00. El script se ejecutara a las 08:00."
echo "El Mac se despertara automaticamente a las 07:58."
echo ""

# ─────────────────────────────────────
#  1. Configurar wake automatico
# ─────────────────────────────────────
echo "Configurando wake automatico del Mac a las 07:58..."
if sudo pmset repeat wakeorpoweron MTWRFSU 07:58:00 2>/dev/null; then
  echo "  Wake automatico configurado: 07:58 cada dia"
else
  echo "  No se pudo configurar wake automatico (necesita sudo)."
  echo "  Configuralo manualmente: Ajustes del Sistema > Bateria > Programacion"
fi
echo ""

# ─────────────────────────────────────
#  2. Crear directorio de logs
# ─────────────────────────────────────
mkdir -p "$DIR/data/logs"

# ─────────────────────────────────────
#  3. Crear launchd plist
# ─────────────────────────────────────
PLIST_PATH="$HOME/Library/LaunchAgents/com.prophunt.daily.plist"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.prophunt.daily</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$DIR/run.sh</string>
        <string>betterplace</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>8</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>WorkingDirectory</key>
    <string>$DIR</string>
    <key>StandardOutPath</key>
    <string>$DIR/data/logs/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$DIR/data/logs/launchd_error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
</dict>
</plist>
EOF

echo "Plist creado: $PLIST_PATH"

# ─────────────────────────────────────
#  4. Cargar en launchd
# ─────────────────────────────────────
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo ""
echo "Cron configurado!"
echo "  Plist: $PLIST_PATH"
echo "  Hora: 08:00 cada dia"
echo "  Modo: betterplace (Gmail -> Chrome -> WhatsApp)"
echo "  Wake: 07:58 cada dia"
echo ""
echo "Comandos utiles:"
echo "  Ver estado:     launchctl list | grep prophunt"
echo "  Ver logs:       tail -f $DIR/data/logs/launchd.log"
echo "  Desactivar:     launchctl unload $PLIST_PATH"
echo "  Test manual:    $DIR/run.sh betterplace"
echo "  Health check:   $DIR/scripts/healthcheck.sh"
