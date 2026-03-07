#!/bin/bash

# ═══════════════════════════════════════════════════════
#  AI PropHunt — Desinstalador
#
#  Uso:
#    ./scripts/uninstall.sh           (interactivo)
#    ./scripts/uninstall.sh --yes     (sin preguntar)
# ═══════════════════════════════════════════════════════

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_PATH="$HOME/Library/LaunchAgents/com.prophunt.daily.plist"
AUTO_YES=false

if [[ "$1" == "--yes" || "$1" == "-y" ]]; then
  AUTO_YES=true
fi

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   AI PropHunt — Desinstalar          ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

if [[ "$AUTO_YES" != true ]]; then
  echo "  Esto eliminara:"
  echo "    - Tarea programada (launchd)"
  echo "    - Carpeta del proyecto ($DIR)"
  echo "    - Datos locales (contactos, logs)"
  echo ""
  echo "  NO eliminara:"
  echo "    - Homebrew, Node.js, jq"
  echo "    - Claude Code CLI"
  echo "    - wacli (WhatsApp CLI)"
  echo "    - Tu cuenta de Supabase (datos en la nube)"
  echo ""
  read -p "  Continuar? (s/n): " confirm
  if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
    echo "  Cancelado."
    exit 0
  fi
  echo ""
fi

# 1. Descargar launchd job
echo "[1/4] Eliminando tarea programada..."
if [[ -f "$PLIST_PATH" ]]; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  echo "       Eliminada: $PLIST_PATH"
else
  echo "       No habia tarea programada"
fi

# 2. Eliminar wake automatico
echo "[2/4] Eliminando wake automatico..."
if sudo pmset repeat cancel 2>/dev/null; then
  echo "       Wake automatico cancelado"
else
  echo "       No se pudo cancelar (necesita sudo o no estaba configurado)"
fi

# 3. Cerrar servidor si esta corriendo
echo "[3/4] Parando servidor..."
SERVER_PID=$(lsof -ti :3456 2>/dev/null || true)
if [[ -n "$SERVER_PID" ]]; then
  kill "$SERVER_PID" 2>/dev/null || true
  echo "       Servidor parado (PID $SERVER_PID)"
else
  echo "       No habia servidor corriendo"
fi

# 4. Eliminar carpeta del proyecto
echo "[4/4] Eliminando archivos..."
if [[ -d "$DIR" && "$DIR" == *"ai-prophunt"* ]]; then
  rm -rf "$DIR"
  echo "       Eliminado: $DIR"
else
  echo "       No se elimino (ruta no coincide con ai-prophunt)"
fi

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   Desinstalacion completada          ║"
echo "  ╚══════════════════════════════════════╝"
echo ""
echo "  Tus datos en Supabase siguen intactos."
echo "  Si quieres eliminarlos, hazlo desde:"
echo "  https://supabase.com/dashboard"
echo ""
