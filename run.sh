#!/bin/bash
cd "$HOME" 2>/dev/null || true

INSTALL_DIR="$(cat "$HOME/.prophunt/install_dir" 2>/dev/null)"
if [[ -z "$INSTALL_DIR" ]] || [[ ! -d "$INSTALL_DIR" ]]; then
  echo "AI PropHunt no esta instalado."
  exit 1
fi

# Find node
if ! command -v node &>/dev/null; then
  SAVED_NODE="$(cat "$HOME/.prophunt/node_bin" 2>/dev/null)"
  if [[ -n "$SAVED_NODE" && -x "$SAVED_NODE" ]]; then
    export PATH="$(dirname "$SAVED_NODE"):$PATH"
  fi
fi

case "${1:-help}" in
  start)
    RUN_NOW=false
    [[ "${2}" == "--run" || "${3}" == "--run" ]] && RUN_NOW=true
    echo "Iniciando AI PropHunt..."
    PLIST="$HOME/Library/LaunchAgents/com.prophunt.server.plist"
    if [[ -f "$PLIST" ]]; then
      launchctl unload "$PLIST" 2>/dev/null
      launchctl load "$PLIST" 2>/dev/null
      sleep 2
      if curl -s http://localhost:3456/health >/dev/null 2>&1; then
        echo "Servidor arrancado (http://localhost:3456)"
      else
        echo "Error al arrancar. Log:"
        tail -5 "$INSTALL_DIR/data/logs/server.log" 2>/dev/null
      fi
    else
      cd "$INSTALL_DIR" && ./run.sh "${2:-server}" &
      echo "Servidor arrancado (PID: $!)"
      sleep 3
    fi
    if $RUN_NOW; then
      echo "Ejecutando pipeline..."
      curl -s -X POST http://localhost:3456/api/run-betterplace \
        -H "Content-Type: application/json" \
        -d '{}' >/dev/null && echo "Pipeline iniciado"
    fi
    ;;
  stop)
    echo "Parando AI PropHunt..."
    launchctl unload "$HOME/Library/LaunchAgents/com.prophunt.server.plist" 2>/dev/null
    pkill -f "server.bundle.cjs\|src/server.js" 2>/dev/null && echo "Parado" || echo "No estaba corriendo"
    ;;
  status)
    if curl -s http://localhost:3456/health >/dev/null 2>&1; then
      echo "AI PropHunt corriendo (http://localhost:3456)"
    else
      echo "AI PropHunt no esta corriendo"
    fi
    echo "Directorio: $INSTALL_DIR"
    if [[ -f "$INSTALL_DIR/.env" ]]; then
      echo "Cuenta: $(grep PROPHUNT_EMAIL "$INSTALL_DIR/.env" | cut -d= -f2)"
    else
      echo "Cuenta: NO CONFIGURADA (ejecuta: prophunt setup)"
    fi
    ;;
  dashboard)
    open "https://prophunt-app.netlify.app/dashboard"
    ;;
  logs)
    LOG_FILE="$INSTALL_DIR/data/logs/$(date +%Y-%m-%d).log"
    if [[ -f "$LOG_FILE" ]]; then cat "$LOG_FILE"
    else echo "No hay logs de hoy"; fi
    ;;
  setup)
    echo "Vinculando cuenta..."
    SB_URL="https://uolymolzgesvxucmbcgw.supabase.co"
    SB_ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVvbHltb2x6Z2Vzdnh1Y21iY2d3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI4NDcwMzgsImV4cCI6MjA4ODQyMzAzOH0.kQfyigV6A6MgnMk2oZaRhCcCla3VcAk2zhtPkFfe9Gc"
    read -p "Email: " USER_EMAIL
    read -sp "Contrasena: " USER_PASSWORD; echo ""
    AUTH_RESULT=$(curl -s "$SB_URL/auth/v1/token?grant_type=password" \
      -H "apikey: $SB_ANON_KEY" -H "Content-Type: application/json" \
      -d "{\"email\": \"$USER_EMAIL\", \"password\": \"$USER_PASSWORD\"}")
    if echo "$AUTH_RESULT" | jq -e '.access_token' > /dev/null 2>&1; then
      cat > "$INSTALL_DIR/.env" <<EOF
SUPABASE_URL=$SB_URL
SUPABASE_ANON_KEY=$SB_ANON_KEY
PROPHUNT_EMAIL=$USER_EMAIL
PROPHUNT_PASSWORD=$USER_PASSWORD
EOF
      echo "Cuenta vinculada correctamente"
    else
      echo "Email o contrasena incorrectos"
    fi
    ;;
  update)
    echo "Actualizando AI PropHunt..."
    REPO="jorgetebl/ai-prophunt"
    RELEASES_URL="https://prophunt-app.netlify.app/releases"
    curl -fL "$RELEASES_URL/server.bundle.cjs" -o "$INSTALL_DIR/server.bundle.cjs" 2>/dev/null && echo "Servidor actualizado" || echo "ERROR servidor"
    curl -fL "$RELEASES_URL/search.bundle.cjs" -o "$INSTALL_DIR/search.bundle.cjs" 2>/dev/null && echo "API search actualizado" || echo "ERROR API search"
    EXT_ZIP="/tmp/prophunt-ext.zip"
    if curl -fL "$RELEASES_URL/chrome-extension.zip" -o "$EXT_ZIP" 2>/dev/null && [[ -s "$EXT_ZIP" ]]; then
      unzip -q -o "$EXT_ZIP" -d "$INSTALL_DIR/chrome-extension"; rm -f "$EXT_ZIP"; echo "Extension actualizada"
    fi
    curl -fL "$RELEASES_URL/run.sh" -o "$INSTALL_DIR/run.sh" 2>/dev/null && chmod +x "$INSTALL_DIR/run.sh" && echo "run.sh actualizado" || true
    curl -fL "$RELEASES_URL/version.json" -o "$INSTALL_DIR/version.json" 2>/dev/null || true
    # Self-update CLI
    curl -fL "$RELEASES_URL/install.sh" -o /tmp/prophunt-install-check.sh 2>/dev/null
    if [[ -s /tmp/prophunt-install-check.sh ]]; then
      awk '/^cat > \/tmp\/prophunt-cli/{found=1;next} /^CLIFEOF$/{found=0;next} found{print}' \
        /tmp/prophunt-install-check.sh > /tmp/prophunt-cli
      if [[ -s /tmp/prophunt-cli ]]; then
        chmod +x /tmp/prophunt-cli
        CLI_PATH="$(command -v prophunt 2>/dev/null)"
        [[ -n "$CLI_PATH" ]] && cp /tmp/prophunt-cli "$CLI_PATH" && chmod +x "$CLI_PATH" && echo "CLI actualizado"
        rm -f /tmp/prophunt-cli
      fi
      rm -f /tmp/prophunt-install-check.sh
    fi
    VERSION=$(cat "$INSTALL_DIR/version.json" 2>/dev/null | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
    echo "Hecho. Ejecuta: prophunt stop && prophunt start"
    echo "Version instalada: v${VERSION:-?}"
    ;;
  --version|-v|version)
    VERSION=$(cat "$INSTALL_DIR/version.json" 2>/dev/null | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
    echo "prophunt v${VERSION:-?}"
    ;;
  uninstall)
    echo ""
    echo "  Esto eliminara AI PropHunt completamente."
    read -p "  Escribe 'si' para confirmar: " CONFIRM
    if [[ "$CONFIRM" != "si" ]]; then echo "Cancelado"; exit 0; fi
    # Backup .env before deleting
    mkdir -p "$HOME/.prophunt"
    cp "$INSTALL_DIR/.env" "$HOME/.prophunt/.env.bak" 2>/dev/null
    launchctl unload "$HOME/Library/LaunchAgents/com.prophunt.server.plist" 2>/dev/null
    pkill -f "server.bundle.cjs\|src/server.js" 2>/dev/null
    rm -rf "$INSTALL_DIR"
    rm -f "$HOME/Library/LaunchAgents/com.prophunt.server.plist"
    sudo rm -f /usr/local/bin/prophunt 2>/dev/null || rm -f /usr/local/bin/prophunt 2>/dev/null
    rm -rf /Applications/PropHunt.app 2>/dev/null
    echo "  Desinstalado. Credenciales guardadas en ~/.prophunt/.env.bak"
    echo "  Para reinstalar: cd ~ && curl -sL https://prophunt-app.netlify.app/releases/install.sh | bash"
    ;;
  *)
    echo ""
    echo "  prophunt start [--run]    Iniciar servidor (--run ejecuta el pipeline inmediatamente)"
    echo "  prophunt stop             Parar servidor"
    echo "  prophunt status           Ver estado"
    echo "  prophunt dashboard        Abrir panel web"
    echo "  prophunt logs             Ver logs de hoy"
    echo "  prophunt setup            Vincular cuenta"
    echo "  prophunt update           Actualizar a la ultima version"
    echo "  prophunt uninstall        Desinstalar completamente"
    echo "  prophunt --version        Ver version instalada"
    echo ""
    ;;
esac
