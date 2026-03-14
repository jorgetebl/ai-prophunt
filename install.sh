#!/bin/bash

# ═══════════════════════════════════════════════════════
#  AI PropHunt — Instalador
#  Uso: curl -sL URL | bash -s -- --setup-token TOKEN
# ═══════════════════════════════════════════════════════

REPO="jorgetebl/ai-prophunt"
INSTALL_DIR="$HOME/ai-prophunt"
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup-token) SETUP_TOKEN_ARG="$2"; shift 2 ;;
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── macOS only ──
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Este instalador es solo para macOS."
  exit 1
fi

# No native binary needed — Node is installed by this script

# ── 1. Homebrew ──
echo "[1/5] Homebrew..."
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
echo "[2/5] jq..."
if command -v jq &>/dev/null; then
  echo "       Ya instalado"
else
  command -v brew &>/dev/null && brew install jq || { echo "       ERROR"; ERRORS+=("jq"); }
fi

# ── 3. wacli ──
echo "[3/5] wacli (WhatsApp CLI)..."
if command -v wacli &>/dev/null; then
  echo "       Ya instalado"
else
  if command -v brew &>/dev/null; then
    brew install steipete/tap/wacli || { echo "       ERROR: No se pudo instalar wacli"; ERRORS+=("wacli"); }
  else
    echo "       ERROR: Necesita Homebrew"; ERRORS+=("wacli")
  fi
fi

# ── 4. Descargar binario y extensión ──
echo "[4/5] Descargando AI PropHunt..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/data/logs"

# Descargar servidor (bundle + launcher)
echo "       Descargando servidor..."
BUNDLE_OK=true
curl -sL "$RELEASES_URL/server.bundle.cjs" -o "$INSTALL_DIR/server.bundle.cjs" || BUNDLE_OK=false
curl -sL "$RELEASES_URL/prophunt-server" -o "$INSTALL_DIR/prophunt-server" || BUNDLE_OK=false
if [[ "$BUNDLE_OK" == "true" ]]; then
  chmod +x "$INSTALL_DIR/prophunt-server"
  echo "       Servidor OK"
else
  echo "       ERROR: No se pudo descargar el servidor"
  ERRORS+=("Servidor")
fi

# Descargar extensión de Chrome
EXT_ZIP="/tmp/prophunt-ext.zip"
EXT_DIR="$INSTALL_DIR/chrome-extension"
echo "       Descargando extensión Chrome..."
if curl -sL "$RELEASES_URL/chrome-extension.zip" -o "$EXT_ZIP"; then
  mkdir -p "$EXT_DIR"
  unzip -q -o "$EXT_ZIP" -d "$EXT_DIR"
  rm -f "$EXT_ZIP"
  echo "       Extensión OK"
else
  echo "       ERROR: No se pudo descargar la extensión"
  ERRORS+=("Extensión Chrome")
fi

# Descargar config de ejemplo si no existe
if [[ ! -f "$INSTALL_DIR/config.json" ]]; then
  curl -sL "https://raw.githubusercontent.com/$REPO/main/config.example.json" \
    -o "$INSTALL_DIR/config.json" 2>/dev/null || true
fi

# Descargar templates
mkdir -p "$INSTALL_DIR/templates"
curl -sL "https://raw.githubusercontent.com/$REPO/main/templates/whatsapp.txt" \
  -o "$INSTALL_DIR/templates/whatsapp.txt" 2>/dev/null || true

# Datos iniciales
[[ ! -f "$INSTALL_DIR/data/contacted.json" ]] && echo '{"contacts":[]}' > "$INSTALL_DIR/data/contacted.json"

# Descargar run.sh
curl -sL "https://raw.githubusercontent.com/$REPO/main/run.sh" \
  -o "$INSTALL_DIR/run.sh" 2>/dev/null && chmod +x "$INSTALL_DIR/run.sh" || true

# ── 5. Vincular cuenta ──
echo "[5/5] Vinculando cuenta..."

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
    echo "  Sin token. Configura despues ejecutando: $INSTALL_DIR/run.sh setup"
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

# ── Instalar app de barra de menú ──
MENUBAR_APP="$INSTALL_DIR/PropHunt.app"
APPS_DEST="/Applications/PropHunt.app"
# (descargado como parte del release si existe)
MENUBAR_URL="$RELEASES_URL/PropHunt.app.zip"
if curl -sI "$MENUBAR_URL" 2>/dev/null | grep -q "200 OK"; then
  curl -sL "$MENUBAR_URL" -o /tmp/prophunt-app.zip
  unzip -q /tmp/prophunt-app.zip -d /tmp/prophunt-app-extract
  cp -r /tmp/prophunt-app-extract/PropHunt.app "$APPS_DEST" 2>/dev/null \
    || sudo cp -r /tmp/prophunt-app-extract/PropHunt.app "$APPS_DEST"
  xattr -rd com.apple.quarantine "$APPS_DEST" 2>/dev/null || true
  osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APPS_DEST\", hidden:true}" 2>/dev/null || true
  open "$APPS_DEST" 2>/dev/null || true
  rm -rf /tmp/prophunt-app.zip /tmp/prophunt-app-extract
fi

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
echo "  Ultimo paso — carga la extension en Chrome:"
echo "    1. Abre Chrome → chrome://extensions"
echo "    2. Activa 'Modo desarrollador' (arriba derecha)"
echo "    3. Pulsa 'Cargar descomprimida'"
echo "    4. Selecciona: $INSTALL_DIR/chrome-extension"
echo ""
echo "  Luego loguéate en idealista.com, fotocasa.es y pisos.com."
echo ""
echo "  Para probar: cd $INSTALL_DIR && ./run.sh test"
echo ""
