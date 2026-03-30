#!/bin/bash

# ═══════════════════════════════════════════════════════
#  AI PropHunt — Instalador
#  Uso: curl -sL URL | bash
# ═══════════════════════════════════════════════════════

# Always start from a safe directory
cd "$HOME" 2>/dev/null || cd / 2>/dev/null

REPO="jorgetebl/ai-prophunt"
INSTALL_DIR="$HOME/ai-prophunt"
RELEASES_URL="https://prophunt-app.netlify.app/releases"
ERRORS=()

# Supabase (public — safe to hardcode)
SB_URL="https://uolymolzgesvxucmbcgw.supabase.co"
SB_ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVvbHltb2x6Z2Vzdnh1Y21iY2d3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI4NDcwMzgsImV4cCI6MjA4ODQyMzAzOH0.kQfyigV6A6MgnMk2oZaRhCcCla3VcAk2zhtPkFfe9Gc"

# ── Args ──
SETUP_TOKEN_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup-token) SETUP_TOKEN_ARG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   AI PropHunt — Instalador           ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# ── macOS only ──
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Este instalador es solo para macOS."
  exit 1
fi

echo "  Instalando en: $INSTALL_DIR"
echo ""

# ══════════════════════════════════════
#  PASO 1: Dependencias del sistema
# ══════════════════════════════════════

echo "[1/5] Instalando dependencias..."

# Homebrew
if ! command -v brew &>/dev/null; then
  echo "       Instalando Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || ERRORS+=("Homebrew")
  [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Node.js
if ! command -v node &>/dev/null; then
  echo "       Instalando Node.js..."
  if command -v brew &>/dev/null; then
    brew install node 2>/dev/null || ERRORS+=("Node.js")
  else
    ERRORS+=("Node.js (Homebrew no disponible)")
  fi
fi

# jq
if ! command -v jq &>/dev/null; then
  command -v brew &>/dev/null && brew install jq 2>/dev/null || ERRORS+=("jq")
fi

# wacli
if ! command -v wacli &>/dev/null; then
  command -v brew &>/dev/null && brew install steipete/tap/wacli 2>/dev/null || ERRORS+=("wacli")
fi

# Verify node exists — check common paths first (which/command -v can fail in piped shells)
NODE_BIN=""
for candidate in /usr/local/bin/node /opt/homebrew/bin/node "$HOME/.nvm/versions/node"/*/bin/node; do
  if [[ -x "$candidate" ]]; then NODE_BIN="$candidate"; break; fi
done
if [[ -z "$NODE_BIN" ]]; then
  NODE_BIN="$(command -v node 2>/dev/null || which node 2>/dev/null || echo "")"
fi

if [[ -z "$NODE_BIN" ]]; then
  echo "       ERROR: Node.js no encontrado"
  ERRORS+=("Node.js")
else
  echo "       Node.js: $($NODE_BIN --version) ($NODE_BIN)"
fi

echo "       Homebrew: $(command -v brew &>/dev/null && echo OK || echo FALTA)"
echo "       jq: $(command -v jq &>/dev/null && echo OK || echo FALTA)"
echo "       wacli: $(command -v wacli &>/dev/null && echo OK || echo FALTA)"

# ══════════════════════════════════════
#  PASO 2: Descargar archivos
# ══════════════════════════════════════

echo ""
echo "[2/5] Descargando AI PropHunt..."

mkdir -p "$INSTALL_DIR/data/logs"

# Server bundle + API search bundle
curl -sfL "$RELEASES_URL/server.bundle.cjs" -o "$INSTALL_DIR/server.bundle.cjs"
curl -sfL "$RELEASES_URL/search.bundle.cjs" -o "$INSTALL_DIR/search.bundle.cjs"
if [[ -s "$INSTALL_DIR/server.bundle.cjs" ]]; then
  echo "       Servidor OK"
else
  echo "       ERROR: servidor"; ERRORS+=("Servidor")
fi

# Chrome extension
EXT_ZIP="/tmp/prophunt-ext.zip"
if curl -sfL "$RELEASES_URL/chrome-extension.zip" -o "$EXT_ZIP" && [[ -s "$EXT_ZIP" ]] && unzip -tq "$EXT_ZIP" >/dev/null 2>&1; then
  mkdir -p "$INSTALL_DIR/chrome-extension"
  unzip -q -o "$EXT_ZIP" -d "$INSTALL_DIR/chrome-extension"
  rm -f "$EXT_ZIP"
  echo "       Extension Chrome OK"
else
  rm -f "$EXT_ZIP"
  echo "       ERROR: extension Chrome"; ERRORS+=("Extension Chrome")
fi

# Config, templates, run.sh
[[ ! -f "$INSTALL_DIR/config.json" ]] && curl -sfL "$RELEASES_URL/config.example.json" -o "$INSTALL_DIR/config.json" 2>/dev/null
mkdir -p "$INSTALL_DIR/templates"
curl -sfL "$RELEASES_URL/whatsapp.txt" -o "$INSTALL_DIR/templates/whatsapp.txt" 2>/dev/null || true
curl -sfL "$RELEASES_URL/run.sh" -o "$INSTALL_DIR/run.sh" 2>/dev/null && chmod +x "$INSTALL_DIR/run.sh" || true
[[ ! -f "$INSTALL_DIR/data/contacted.json" ]] && echo '{"contacts":[]}' > "$INSTALL_DIR/data/contacted.json"

# ══════════════════════════════════════
#  PASO 3: Vincular cuenta
# ══════════════════════════════════════

echo ""
echo "[3/5] Vinculando cuenta..."

# Check if .env already exists (from backup or previous install)
if [[ -f "$INSTALL_DIR/.env" ]] && grep -q "PROPHUNT_EMAIL=.\+" "$INSTALL_DIR/.env" 2>/dev/null; then
  EMAIL=$(grep PROPHUNT_EMAIL "$INSTALL_DIR/.env" | cut -d= -f2)
  echo "       Ya configurado ($EMAIL)"
elif [[ -f "$HOME/.prophunt/.env.bak" ]]; then
  # Restore from backup (saved during uninstall)
  cp "$HOME/.prophunt/.env.bak" "$INSTALL_DIR/.env"
  EMAIL=$(grep PROPHUNT_EMAIL "$INSTALL_DIR/.env" | cut -d= -f2)
  echo "       Restaurado desde backup ($EMAIL)"
else
  # Need to link account
  if [[ -n "$SETUP_TOKEN_ARG" ]]; then
    SETUP_TOKEN="$SETUP_TOKEN_ARG"
  else
    echo ""
    echo "  Necesitas vincular tu cuenta."
    echo "  Puedes usar un token (del dashboard) o email+contrasena."
    echo ""
    echo "    1) Email y contrasena"
    echo "    2) Token de instalacion"
    echo ""
    read -p "  Elige [1/2]: " LINK_CHOICE < /dev/tty
  fi

  if [[ "$LINK_CHOICE" == "1" ]]; then
    # Direct email+password login
    read -p "  Email: " USER_EMAIL < /dev/tty
    read -sp "  Contrasena: " USER_PASSWORD < /dev/tty
    echo ""
    AUTH_RESULT=$(curl -s "$SB_URL/auth/v1/token?grant_type=password" \
      -H "apikey: $SB_ANON_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"email\": \"$USER_EMAIL\", \"password\": \"$USER_PASSWORD\"}")
    if echo "$AUTH_RESULT" | jq -e '.access_token' > /dev/null 2>&1; then
      cat > "$INSTALL_DIR/.env" <<ENVEOF
SUPABASE_URL=$SB_URL
SUPABASE_ANON_KEY=$SB_ANON_KEY
PROPHUNT_EMAIL=$USER_EMAIL
PROPHUNT_PASSWORD=$USER_PASSWORD
ENVEOF
      echo "       Cuenta vinculada"
    else
      echo "       Email o contrasena incorrectos"
      ERRORS+=("Vinculacion de cuenta")
    fi
  else
    # Token-based linking
    if [[ -z "${SETUP_TOKEN:-}" ]]; then
      echo "  Genera un token en: https://prophunt-app.netlify.app/dashboard"
      read -p "  Token: " SETUP_TOKEN < /dev/tty
    fi
    if [[ -n "$SETUP_TOKEN" ]]; then
      VALIDATION=$(curl -s "$SB_URL/rest/v1/rpc/validate_setup_token" \
        -H "apikey: $SB_ANON_KEY" -H "Authorization: Bearer $SB_ANON_KEY" \
        -H "Content-Type: application/json" -d "{\"setup_token\": \"$SETUP_TOKEN\"}")
      VALID=$(echo "$VALIDATION" | jq -r '.valid // false' 2>/dev/null)
      if [[ "$VALID" == "true" ]]; then
        USER_EMAIL=$(echo "$VALIDATION" | jq -r '.email')
        echo "  Cuenta: $USER_EMAIL"
        read -sp "  Contrasena: " USER_PASSWORD < /dev/tty
        echo ""
        AUTH_RESULT=$(curl -s "$SB_URL/auth/v1/token?grant_type=password" \
          -H "apikey: $SB_ANON_KEY" -H "Content-Type: application/json" \
          -d "{\"email\": \"$USER_EMAIL\", \"password\": \"$USER_PASSWORD\"}")
        if echo "$AUTH_RESULT" | jq -e '.access_token' > /dev/null 2>&1; then
          cat > "$INSTALL_DIR/.env" <<ENVEOF
SUPABASE_URL=$SB_URL
SUPABASE_ANON_KEY=$SB_ANON_KEY
PROPHUNT_EMAIL=$USER_EMAIL
PROPHUNT_PASSWORD=$USER_PASSWORD
ENVEOF
          echo "       Cuenta vinculada"
        else
          echo "       Contrasena incorrecta"
          ERRORS+=("Vinculacion de cuenta")
        fi
      else
        echo "       Token invalido o expirado"
        ERRORS+=("Vinculacion de cuenta")
      fi
    else
      echo "       Sin token. Ejecuta: prophunt setup"
      ERRORS+=("Vinculacion de cuenta")
    fi
  fi
fi

# ══════════════════════════════════════
#  PASO 4: Comando prophunt + CLI
# ══════════════════════════════════════

echo ""
echo "[4/5] Instalando comando 'prophunt'..."

mkdir -p "$HOME/.prophunt"
echo "$INSTALL_DIR" > "$HOME/.prophunt/install_dir"
[[ -n "$NODE_BIN" ]] && echo "$NODE_BIN" > "$HOME/.prophunt/node_bin"

cat > /tmp/prophunt-cli <<'CLIFEOF'
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
    echo "  prophunt start            Iniciar servidor"
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
CLIFEOF

if sudo cp /tmp/prophunt-cli /usr/local/bin/prophunt 2>/dev/null && sudo chmod +x /usr/local/bin/prophunt 2>/dev/null; then
  echo "       OK"
else
  mkdir -p "$HOME/.local/bin"
  cp /tmp/prophunt-cli "$HOME/.local/bin/prophunt" && chmod +x "$HOME/.local/bin/prophunt"
  echo "$PATH" | grep -q "$HOME/.local/bin" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile"
  echo "       OK (en ~/.local/bin/)"
fi
rm -f /tmp/prophunt-cli

# ══════════════════════════════════════
#  PASO 5: Autoarranque + verificacion
# ══════════════════════════════════════

echo ""
echo "[5/5] Configurando servidor..."

# Create start script — finds node at runtime so it always works
cat > "$INSTALL_DIR/start-server.sh" <<'WRAPEOF'
#!/bin/bash
cd "$HOME/ai-prophunt" || exit 1
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
NODE="$(command -v node 2>/dev/null)"
if [[ -z "$NODE" ]]; then
  for c in /usr/local/bin/node /opt/homebrew/bin/node; do
    [[ -x "$c" ]] && NODE="$c" && break
  done
fi
if [[ -z "$NODE" ]]; then echo "ERROR: node no encontrado"; exit 1; fi
exec "$NODE" "$HOME/ai-prophunt/server.bundle.cjs"
WRAPEOF
chmod +x "$INSTALL_DIR/start-server.sh"

# Create LaunchAgent
PLIST_PATH="$HOME/Library/LaunchAgents/com.prophunt.server.plist"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.prophunt.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_DIR/start-server.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>$INSTALL_DIR/data/logs/server.log</string>
  <key>StandardErrorPath</key>
  <string>$INSTALL_DIR/data/logs/server.log</string>
</dict>
</plist>
PLISTEOF

# Start server
launchctl unload "$PLIST_PATH" 2>/dev/null
> "$INSTALL_DIR/data/logs/server.log"
launchctl load "$PLIST_PATH" 2>/dev/null

# Wait and verify
echo "       Arrancando servidor..."
sleep 3
if curl -s http://localhost:3456/health >/dev/null 2>&1; then
  echo "       Servidor OK (http://localhost:3456)"
else
  echo "       AVISO: Servidor no responde aun. Log:"
  tail -3 "$INSTALL_DIR/data/logs/server.log" 2>/dev/null | sed 's/^/       /'
  ERRORS+=("Servidor no arranco")
fi

# ── WhatsApp ──
echo ""
echo "Vinculando WhatsApp..."
if ! command -v wacli &>/dev/null; then
  echo "  wacli no disponible"
elif wacli doctor 2>&1 | grep -qi "connected\|authenticated\|ok"; then
  echo "  Ya vinculado"
else
  echo "  Escanea el QR con tu WhatsApp:"
  wacli auth < /dev/tty || echo "  Ejecuta despues: wacli auth"
fi

# ══════════════════════════════════════
#  RESULTADO
# ══════════════════════════════════════

echo ""
if [[ ${#ERRORS[@]} -eq 0 ]]; then
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║   Instalacion completada!            ║"
  echo "  ╚══════════════════════════════════════╝"
else
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║   Completado con avisos              ║"
  echo "  ╚══════════════════════════════════════╝"
  echo ""
  for err in "${ERRORS[@]}"; do echo "  - $err"; done
fi
echo ""
echo "  Directorio: $INSTALL_DIR"
echo "  Servidor:   http://localhost:3456"
echo ""
echo "  Comandos: prophunt start | stop | status | update | uninstall"
echo ""
echo "  Extension Chrome:"
echo "    1. chrome://extensions → Modo desarrollador ON"
echo "    2. Cargar descomprimida → $INSTALL_DIR/chrome-extension"
echo ""
