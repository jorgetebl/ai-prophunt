#!/bin/bash

# ═══════════════════════════════════════════════════════
#  AI PropHunt — Instalador
#  Uso: curl -sL URL | bash -s -- [--setup-token TOKEN] [--dir PATH]
# ═══════════════════════════════════════════════════════

REPO="jorgetebl/ai-prophunt"
RELEASES_URL="https://github.com/$REPO/releases/download/latest"
ERRORS=()

# Supabase (public — safe to hardcode)
SB_URL="https://uolymolzgesvxucmbcgw.supabase.co"
SB_ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVvbHltb2x6Z2Vzdnh1Y21iY2d3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI4NDcwMzgsImV4cCI6MjA4ODQyMzAzOH0.kQfyigV6A6MgnMk2oZaRhCcCla3VcAk2zhtPkFfe9Gc"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   AI PropHunt — Instalador           ║"
echo "  ║   REMAX Experience                   ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# ── Args ──
SETUP_TOKEN_ARG=""
INSTALL_DIR_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup-token) SETUP_TOKEN_ARG="$2"; shift 2 ;;
    --dir) INSTALL_DIR_ARG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── macOS only ──
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Este instalador es solo para macOS."
  exit 1
fi

# ── Directorio de instalacion (fijo en ~/ai-prophunt para evitar problemas de permisos) ──
INSTALL_DIR="${INSTALL_DIR_ARG:-$HOME/ai-prophunt}"
echo "  Instalando en: $INSTALL_DIR"
echo ""

# ── 1. Homebrew ──
echo "[1/6] Homebrew..."
if command -v brew &>/dev/null; then
  echo "       Ya instalado"
else
  echo "       Instalando Homebrew (puede pedir contraseña del Mac)..."
  if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
    if [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    fi
  else
    echo "       ERROR: No se pudo instalar Homebrew"
    ERRORS+=("Homebrew")
  fi
fi

# ── 2. jq ──
echo "[2/6] jq..."
if command -v jq &>/dev/null; then
  echo "       Ya instalado"
else
  command -v brew &>/dev/null && brew install jq || { echo "       ERROR"; ERRORS+=("jq"); }
fi

# ── 3. wacli ──
echo "[3/6] wacli (WhatsApp CLI)..."
if command -v wacli &>/dev/null; then
  echo "       Ya instalado"
else
  if command -v brew &>/dev/null; then
    brew install steipete/tap/wacli || { echo "       ERROR: No se pudo instalar wacli"; ERRORS+=("wacli"); }
  else
    echo "       ERROR: Necesita Homebrew"; ERRORS+=("wacli")
  fi
fi

# ── 4. Descargar archivos ──
echo "[4/6] Descargando AI PropHunt..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/data/logs"

# Descargar servidor (bundle + launcher)
echo "       Descargando servidor..."
BUNDLE_OK=true
curl -sfL "$RELEASES_URL/server.bundle.cjs" -o "$INSTALL_DIR/server.bundle.cjs" || BUNDLE_OK=false
curl -sfL "$RELEASES_URL/prophunt-server" -o "$INSTALL_DIR/prophunt-server" || BUNDLE_OK=false
if [[ "$BUNDLE_OK" == "true" ]] && [[ -s "$INSTALL_DIR/server.bundle.cjs" ]]; then
  chmod +x "$INSTALL_DIR/prophunt-server"
  echo "       Servidor OK"
else
  rm -f "$INSTALL_DIR/server.bundle.cjs" "$INSTALL_DIR/prophunt-server"
  echo "       ERROR: No se pudo descargar el servidor"
  ERRORS+=("Servidor")
fi

# Descargar extensión de Chrome
EXT_ZIP="/tmp/prophunt-ext.zip"
EXT_DIR="$INSTALL_DIR/chrome-extension"
echo "       Descargando extension Chrome..."
if curl -sfL "$RELEASES_URL/chrome-extension.zip" -o "$EXT_ZIP" && [[ -s "$EXT_ZIP" ]] && unzip -tq "$EXT_ZIP" >/dev/null 2>&1; then
  mkdir -p "$EXT_DIR"
  unzip -q -o "$EXT_ZIP" -d "$EXT_DIR"
  rm -f "$EXT_ZIP"
  # Verificar que los archivos se extrajeron
  if [[ -f "$EXT_DIR/manifest.json" ]]; then
    echo "       Extension OK"
  else
    echo "       ERROR: El zip se descargo pero no contiene la extension"
    ERRORS+=("Extension Chrome (zip corrupto)")
  fi
else
  rm -f "$EXT_ZIP"
  echo "       ERROR: No se pudo descargar la extension"
  ERRORS+=("Extension Chrome")
fi

# Descargar config de ejemplo si no existe
if [[ ! -f "$INSTALL_DIR/config.json" ]]; then
  curl -sfL "https://raw.githubusercontent.com/$REPO/main/config.example.json" \
    -o "$INSTALL_DIR/config.json" 2>/dev/null || true
fi

# Descargar templates
mkdir -p "$INSTALL_DIR/templates"
curl -sfL "https://raw.githubusercontent.com/$REPO/main/templates/whatsapp.txt" \
  -o "$INSTALL_DIR/templates/whatsapp.txt" 2>/dev/null || true

# Datos iniciales
[[ ! -f "$INSTALL_DIR/data/contacted.json" ]] && echo '{"contacts":[]}' > "$INSTALL_DIR/data/contacted.json"

# Descargar run.sh
curl -sfL "https://raw.githubusercontent.com/$REPO/main/run.sh" \
  -o "$INSTALL_DIR/run.sh" 2>/dev/null && chmod +x "$INSTALL_DIR/run.sh" || true

# ── 5. Vincular cuenta ──
echo "[5/6] Vinculando cuenta..."

SKIP_SETUP=false
if [[ -f "$INSTALL_DIR/.env" ]] && grep -q "PROPHUNT_EMAIL=.\+" "$INSTALL_DIR/.env" 2>/dev/null; then
  echo "       Ya configurado"
  SKIP_SETUP=true
fi

if [[ "$SKIP_SETUP" != "true" ]]; then
  if [[ -n "$SETUP_TOKEN_ARG" ]]; then
    SETUP_TOKEN="$SETUP_TOKEN_ARG"
  else
    echo ""
    echo "  Necesitas un token de instalacion."
    echo "  Generalo en: https://prophunt-app.netlify.app/dashboard"
    echo ""
    read -p "  Token: " SETUP_TOKEN < /dev/tty
  fi

  if [[ -z "$SETUP_TOKEN" ]]; then
    echo "  Sin token. Configura despues ejecutando: prophunt setup"
  else
    VALIDATION=$(curl -s "$SB_URL/rest/v1/rpc/validate_setup_token" \
      -H "apikey: $SB_ANON_KEY" \
      -H "Authorization: Bearer $SB_ANON_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"setup_token\": \"$SETUP_TOKEN\"}")

    VALID=$(echo "$VALIDATION" | jq -r '.valid // false' 2>/dev/null)
    if [[ "$VALID" != "true" ]]; then
      echo "  Token invalido o expirado. Genera uno nuevo en el dashboard."
      ERRORS+=("Vinculacion de cuenta")
    else
      USER_EMAIL=$(echo "$VALIDATION" | jq -r '.email')
      echo "  Cuenta: $USER_EMAIL"
      read -sp "  Contrasena de PropHunt: " USER_PASSWORD < /dev/tty
      echo ""

      AUTH_RESULT=$(curl -s "$SB_URL/auth/v1/token?grant_type=password" \
        -H "apikey: $SB_ANON_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$USER_EMAIL\", \"password\": \"$USER_PASSWORD\"}")

      if echo "$AUTH_RESULT" | jq -e '.access_token' > /dev/null 2>&1; then
        echo "  Cuenta vinculada"
        cat > "$INSTALL_DIR/.env" <<ENVEOF
# Supabase
SUPABASE_URL=$SB_URL
SUPABASE_ANON_KEY=$SB_ANON_KEY
PROPHUNT_EMAIL=$USER_EMAIL
PROPHUNT_PASSWORD=$USER_PASSWORD
ENVEOF
      else
        echo "  Contrasena incorrecta."
        ERRORS+=("Vinculacion de cuenta")
      fi
    fi
  fi
fi

# ── 6. Instalar comando prophunt ──
echo "[6/6] Instalando comando 'prophunt'..."

# Guardar ruta de instalacion para que el comando sepa donde buscar
mkdir -p "$HOME/.prophunt"
echo "$INSTALL_DIR" > "$HOME/.prophunt/install_dir"

PROPHUNT_BIN="/usr/local/bin/prophunt"
cat > /tmp/prophunt-cli <<'CLIFEOF'
#!/bin/bash

# AI PropHunt — CLI
# Fix getcwd errors if current dir was deleted
cd "$HOME" 2>/dev/null || true

INSTALL_DIR="$(cat "$HOME/.prophunt/install_dir" 2>/dev/null)"

if [[ -z "$INSTALL_DIR" ]] || [[ ! -d "$INSTALL_DIR" ]]; then
  echo "AI PropHunt no esta instalado."
  echo "Instala con: curl -sL https://raw.githubusercontent.com/jorgetebl/ai-prophunt/main/install.sh | bash"
  exit 1
fi

case "${1:-help}" in
  start)
    echo "Iniciando AI PropHunt..."
    PLIST="$HOME/Library/LaunchAgents/com.prophunt.server.plist"
    if [[ -f "$PLIST" ]]; then
      launchctl unload "$PLIST" 2>/dev/null
      launchctl load "$PLIST" 2>/dev/null
      sleep 1
      if pgrep -f "run.sh.*server\|prophunt-server\|server.bundle.cjs" >/dev/null 2>&1; then
        echo "Servidor arrancado"
      else
        echo "Error al arrancar. Revisa: cat $INSTALL_DIR/data/logs/server.log"
      fi
    else
      cd "$INSTALL_DIR" && ./run.sh "${2:-server}" &
      echo "Servidor arrancado (PID: $!)"
    fi
    ;;
  stop)
    echo "Parando AI PropHunt..."
    PLIST="$HOME/Library/LaunchAgents/com.prophunt.server.plist"
    launchctl unload "$PLIST" 2>/dev/null
    pkill -f "prophunt-server\|server.bundle.cjs\|run.sh.*server" 2>/dev/null && echo "Parado" || echo "No estaba corriendo"
    ;;
  status)
    if pgrep -f "prophunt-server\|server.bundle.cjs" >/dev/null 2>&1; then
      PID=$(pgrep -f "prophunt-server\|server.bundle.cjs" | head -1)
      echo "AI PropHunt corriendo (PID: $PID)"
    else
      echo "AI PropHunt no esta corriendo"
    fi
    echo "Directorio: $INSTALL_DIR"
    if [[ -f "$INSTALL_DIR/.env" ]]; then
      EMAIL=$(grep PROPHUNT_EMAIL "$INSTALL_DIR/.env" | cut -d= -f2)
      echo "Cuenta: $EMAIL"
    fi
    ;;
  dashboard)
    echo "Abriendo dashboard..."
    open "https://prophunt-app.netlify.app/dashboard"
    ;;
  logs)
    LOG_FILE="$INSTALL_DIR/data/logs/$(date +%Y-%m-%d).log"
    if [[ -f "$LOG_FILE" ]]; then
      cat "$LOG_FILE"
    else
      echo "No hay logs de hoy"
    fi
    ;;
  setup)
    echo "Reconfigurando cuenta..."
    SB_URL="https://uolymolzgesvxucmbcgw.supabase.co"
    SB_ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVvbHltb2x6Z2Vzdnh1Y21iY2d3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI4NDcwMzgsImV4cCI6MjA4ODQyMzAzOH0.kQfyigV6A6MgnMk2oZaRhCcCla3VcAk2zhtPkFfe9Gc"
    echo "Genera un token en: https://prophunt-app.netlify.app/dashboard"
    read -p "Token: " SETUP_TOKEN
    if [[ -z "$SETUP_TOKEN" ]]; then echo "Cancelado"; exit 0; fi
    VALIDATION=$(curl -s "$SB_URL/rest/v1/rpc/validate_setup_token" \
      -H "apikey: $SB_ANON_KEY" -H "Authorization: Bearer $SB_ANON_KEY" \
      -H "Content-Type: application/json" -d "{\"setup_token\": \"$SETUP_TOKEN\"}")
    VALID=$(echo "$VALIDATION" | jq -r '.valid // false' 2>/dev/null)
    if [[ "$VALID" != "true" ]]; then echo "Token invalido o expirado."; exit 1; fi
    USER_EMAIL=$(echo "$VALIDATION" | jq -r '.email')
    echo "Cuenta: $USER_EMAIL"
    read -sp "Contrasena: " USER_PASSWORD; echo ""
    AUTH_RESULT=$(curl -s "$SB_URL/auth/v1/token?grant_type=password" \
      -H "apikey: $SB_ANON_KEY" -H "Content-Type: application/json" \
      -d "{\"email\": \"$USER_EMAIL\", \"password\": \"$USER_PASSWORD\"}")
    if echo "$AUTH_RESULT" | jq -e '.access_token' > /dev/null 2>&1; then
      cat > "$INSTALL_DIR/.env" <<EOF
# Supabase
SUPABASE_URL=$SB_URL
SUPABASE_ANON_KEY=$SB_ANON_KEY
PROPHUNT_EMAIL=$USER_EMAIL
PROPHUNT_PASSWORD=$USER_PASSWORD
EOF
      echo "Cuenta vinculada correctamente"
    else
      echo "Contrasena incorrecta"
    fi
    ;;
  update)
    echo "Actualizando AI PropHunt..."
    REPO="jorgetebl/ai-prophunt"
    RELEASES_URL="https://github.com/$REPO/releases/download/latest"
    curl -sfL "$RELEASES_URL/server.bundle.cjs" -o "$INSTALL_DIR/server.bundle.cjs" && echo "Servidor actualizado" || echo "ERROR descargando servidor"
    curl -sfL "$RELEASES_URL/prophunt-server" -o "$INSTALL_DIR/prophunt-server" && chmod +x "$INSTALL_DIR/prophunt-server" && echo "Launcher actualizado" || echo "ERROR descargando launcher"
    EXT_ZIP="/tmp/prophunt-ext.zip"
    if curl -sfL "$RELEASES_URL/chrome-extension.zip" -o "$EXT_ZIP" && [[ -s "$EXT_ZIP" ]] && unzip -tq "$EXT_ZIP" >/dev/null 2>&1; then
      unzip -q -o "$EXT_ZIP" -d "$INSTALL_DIR/chrome-extension"
      rm -f "$EXT_ZIP"
      echo "Extension actualizada"
    fi
    curl -sfL "https://raw.githubusercontent.com/$REPO/main/run.sh" -o "$INSTALL_DIR/run.sh" && chmod +x "$INSTALL_DIR/run.sh" && echo "run.sh actualizado" || true
    # Actualizar el propio comando prophunt
    curl -sfL "https://raw.githubusercontent.com/$REPO/main/install.sh" -o /tmp/prophunt-install-check.sh 2>/dev/null
    echo "Hecho"
    ;;
  uninstall)
    echo ""
    echo "  Esto eliminara:"
    echo "    - $INSTALL_DIR (todos los archivos)"
    echo "    - /usr/local/bin/prophunt (comando CLI)"
    echo "    - $HOME/.prophunt (configuracion)"
    echo "    - Autoarranque (LaunchAgent)"
    echo ""
    read -p "  Estas seguro? (escribe 'si' para confirmar): " CONFIRM
    if [[ "$CONFIRM" != "si" ]]; then echo "Cancelado"; exit 0; fi
    echo ""
    echo "  Parando servidor..."
    launchctl unload "$HOME/Library/LaunchAgents/com.prophunt.server.plist" 2>/dev/null
    pkill -f "prophunt-server\|server.bundle.cjs" 2>/dev/null
    echo "  Eliminando archivos..."
    rm -rf "$INSTALL_DIR"
    rm -rf "$HOME/.prophunt"
    rm -f "$HOME/Library/LaunchAgents/com.prophunt.server.plist"
    sudo rm -f /usr/local/bin/prophunt 2>/dev/null || rm -f /usr/local/bin/prophunt 2>/dev/null
    echo "  AI PropHunt desinstalado"
    echo ""
    echo "  Nota: Homebrew, jq y wacli NO se han desinstalado."
    echo "  Para eliminarlos: brew uninstall wacli jq"
    ;;
  help|--help|-h|*)
    echo ""
    echo "  AI PropHunt — Comandos"
    echo ""
    echo "    prophunt start [mode]   Iniciar (modes: server, api, dashboard, betterplace)"
    echo "    prophunt stop           Parar el servidor"
    echo "    prophunt status         Ver estado"
    echo "    prophunt dashboard      Abrir dashboard en el navegador"
    echo "    prophunt logs           Ver logs de hoy"
    echo "    prophunt setup          Vincular/reconfigurar cuenta"
    echo "    prophunt update         Actualizar a la ultima version"
    echo "    prophunt uninstall      Desinstalar completamente"
    echo ""
    echo "  Directorio: $INSTALL_DIR"
    echo ""
    ;;
esac
CLIFEOF

if sudo cp /tmp/prophunt-cli "$PROPHUNT_BIN" 2>/dev/null && sudo chmod +x "$PROPHUNT_BIN" 2>/dev/null; then
  rm -f /tmp/prophunt-cli
  echo "       Comando 'prophunt' instalado"
else
  # Fallback sin sudo
  mkdir -p "$HOME/.local/bin"
  cp /tmp/prophunt-cli "$HOME/.local/bin/prophunt"
  chmod +x "$HOME/.local/bin/prophunt"
  rm -f /tmp/prophunt-cli
  # Añadir a PATH si no esta
  if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile"
    export PATH="$HOME/.local/bin:$PATH"
  fi
  echo "       Comando 'prophunt' instalado en ~/.local/bin/"
fi

# ── Instalar app de barra de menu ──
APPS_DEST="/Applications/PropHunt.app"
MENUBAR_URL="$RELEASES_URL/PropHunt.app.zip"
if curl -sfI "$MENUBAR_URL" >/dev/null 2>&1; then
  echo ""
  echo "Instalando app de barra de menu..."
  if curl -sfL "$MENUBAR_URL" -o /tmp/prophunt-app.zip && [[ -s /tmp/prophunt-app.zip ]]; then
    unzip -q -o /tmp/prophunt-app.zip -d /tmp/prophunt-app-extract
    cp -r /tmp/prophunt-app-extract/PropHunt.app "$APPS_DEST" 2>/dev/null \
      || sudo cp -r /tmp/prophunt-app-extract/PropHunt.app "$APPS_DEST"
    xattr -rd com.apple.quarantine "$APPS_DEST" 2>/dev/null || true
    osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APPS_DEST\", hidden:true}" 2>/dev/null || true
    open "$APPS_DEST" 2>/dev/null || true
    rm -rf /tmp/prophunt-app.zip /tmp/prophunt-app-extract
    echo "  App instalada en /Applications"
  fi
fi

# ── 7. Autoarranque al encender el Mac ──
echo ""
echo "Configurando autoarranque..."
PLIST_NAME="com.prophunt.server"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
mkdir -p "$HOME/Library/LaunchAgents"

# Determinar ruta del ejecutable
if [[ -f "$INSTALL_DIR/prophunt-server" ]]; then
  SERVER_CMD="$INSTALL_DIR/prophunt-server"
else
  SERVER_CMD="/usr/bin/env node $INSTALL_DIR/server.bundle.cjs"
fi

cat > "$PLIST_PATH" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PLIST_NAME</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_DIR/run.sh</string>
    <string>server</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$INSTALL_DIR</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$INSTALL_DIR/data/logs/server.log</string>
  <key>StandardErrorPath</key>
  <string>$INSTALL_DIR/data/logs/server.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLISTEOF

# Cargar el LaunchAgent (para ahora y futuros reinicios)
launchctl unload "$PLIST_PATH" 2>/dev/null
launchctl load "$PLIST_PATH" 2>/dev/null
echo "  Servidor configurado para arrancar automaticamente"

# ── Vincular WhatsApp ──
echo ""
echo "Vinculando WhatsApp..."
if ! command -v wacli &>/dev/null; then
  echo "  wacli no disponible. Instala wacli y ejecuta: wacli auth"
  ERRORS+=("WhatsApp (wacli no instalado)")
elif wacli doctor 2>&1 | grep -qi "connected\|authenticated\|ok"; then
  echo "  Ya vinculado"
else
  echo "  Escanea el QR con tu WhatsApp para vincular:"
  echo ""
  wacli auth < /dev/tty || echo "  Puedes vincularlo despues: wacli auth"
fi

# ── Resultado ──
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
echo ""
echo "  El servidor arranca automaticamente (incluso al reiniciar)."
echo ""
echo "  Comandos disponibles:"
echo "    prophunt start       Iniciar el servidor"
echo "    prophunt stop        Parar el servidor"
echo "    prophunt status      Ver estado"
echo "    prophunt dashboard   Abrir panel web"
echo "    prophunt logs        Ver logs de hoy"
echo "    prophunt update      Actualizar"
echo "    prophunt uninstall   Desinstalar"
echo ""
echo "  Carga la extension en Chrome:"
echo "    1. Abre Chrome -> chrome://extensions"
echo "    2. Activa 'Modo desarrollador' (arriba derecha)"
echo "    3. Pulsa 'Cargar descomprimida'"
echo "    4. Selecciona: $INSTALL_DIR/chrome-extension"
echo ""
echo "  Luego logueate en idealista.com, fotocasa.es y pisos.com."
echo ""
