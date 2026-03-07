#!/bin/bash
set -e

# ═══════════════════════════════════════════════════════
#  AI PropHunt — Instalador remoto
#
#  Uso:
#    curl -sL URL | bash
#    o
#    curl -sL URL | bash -s -- --token GITHUB_PAT
# ═══════════════════════════════════════════════════════

REPO="jorgetebl/ai-prophunt"
INSTALL_DIR="$HOME/ai-prophunt"
BRANCH="main"

# Supabase (public keys — safe to hardcode)
SB_URL="https://uolymolzgesvxucmbcgw.supabase.co"
SB_ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVvbHltb2x6Z2Vzdnh1Y21iY2d3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI4NDcwMzgsImV4cCI6MjA4ODQyMzAzOH0.kQfyigV6A6MgnMk2oZaRhCcCla3VcAk2zhtPkFfe9Gc"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   AI PropHunt — Instalador           ║"
echo "  ║   REMAX Experience                   ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# Parse args
GH_TOKEN=""
SETUP_TOKEN_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) GH_TOKEN="$2"; shift 2 ;;
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --setup-token) SETUP_TOKEN_ARG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── macOS check ──
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Este instalador es solo para macOS."
  exit 1
fi

# ── Homebrew ──
echo "[1/9] Homebrew..."
if command -v brew &>/dev/null; then
  echo "       Ya instalado"
else
  echo "       Instalando Homebrew (puede pedir contraseña del Mac)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add to PATH for Apple Silicon
  if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
  fi
fi

# ── Node.js ──
echo "[2/9] Node.js..."
if command -v node &>/dev/null; then
  echo "       Ya instalado ($(node -v))"
else
  echo "       Instalando..."
  brew install node
fi

# ── jq ──
echo "[3/9] jq..."
if command -v jq &>/dev/null; then
  echo "       Ya instalado"
else
  brew install jq
fi

# ── Claude Code CLI ──
echo "[4/9] Claude Code CLI..."
if command -v claude &>/dev/null; then
  echo "       Ya instalado"
else
  echo "       Instalando..."
  npm install -g @anthropic-ai/claude-code
fi

# ── wacli ──
echo "[5/9] wacli (WhatsApp CLI)..."
if command -v wacli &>/dev/null; then
  echo "       Ya instalado"
else
  echo "       Instalando..."
  brew install steipete/tap/wacli
fi

# ── Descargar proyecto ──
echo "[6/9] Descargando AI PropHunt..."
if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo "       Ya existe en $INSTALL_DIR, actualizando..."
  cd "$INSTALL_DIR" && git pull origin "$BRANCH" 2>/dev/null || true
else
  if [[ -d "$INSTALL_DIR" ]]; then
    echo "       Directorio existe pero no es git, haciendo backup..."
    mv "$INSTALL_DIR" "$INSTALL_DIR.bak.$(date +%s)"
  fi

  if command -v git &>/dev/null; then
    if [[ -n "$GH_TOKEN" ]]; then
      git clone "https://$GH_TOKEN@github.com/$REPO.git" "$INSTALL_DIR"
    else
      git clone "https://github.com/$REPO.git" "$INSTALL_DIR"
    fi
  else
    # Sin git: descargar ZIP
    echo "       git no disponible, descargando ZIP..."
    ZIP_URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.zip"
    if [[ -n "$GH_TOKEN" ]]; then
      curl -sL -H "Authorization: token $GH_TOKEN" "$ZIP_URL" -o /tmp/prophunt.zip
    else
      curl -sL "$ZIP_URL" -o /tmp/prophunt.zip
    fi
    unzip -q /tmp/prophunt.zip -d /tmp/prophunt_extract
    mv /tmp/prophunt_extract/ai-prophunt-$BRANCH "$INSTALL_DIR"
    rm -rf /tmp/prophunt.zip /tmp/prophunt_extract
  fi
fi

cd "$INSTALL_DIR"

# ── Configurar proyecto ──
echo "[7/9] Configurando proyecto..."
chmod +x run.sh setup.sh scripts/*.sh 2>/dev/null || true
mkdir -p data/logs

if [[ ! -f config.json ]] && [[ -f config.example.json ]]; then
  cp config.example.json config.json
fi

if [[ ! -f data/contacted.json ]]; then
  echo '{"contacts":[]}' > data/contacted.json
fi

npm install --silent 2>/dev/null || true

# ── Vincular WhatsApp ──
echo "[8/9] Vinculando WhatsApp..."
if wacli doctor 2>&1 | grep -qi "connected\|authenticated\|ok"; then
  echo "       Ya vinculado"
else
  echo ""
  echo "  Necesitas escanear un QR con WhatsApp para vincular."
  echo "  Se abrira el proceso de autenticacion de wacli."
  echo ""
  wacli auth < /dev/tty || echo "       No se pudo vincular. Puedes hacerlo despues con: wacli auth"
fi

# ── Vincular cuenta con token de instalacion ──
echo "[9/9] Vinculando cuenta..."

# Check if .env already has valid credentials
if [[ -f .env ]] && grep -q "PROPHUNT_EMAIL=.\+" .env && grep -q "PROPHUNT_PASSWORD=.\+" .env; then
  echo "       Ya configurado"
  SKIP_SETUP=true
fi

if [[ "$SKIP_SETUP" != "true" ]]; then
  if [[ -n "$SETUP_TOKEN_ARG" ]]; then
    SETUP_TOKEN="$SETUP_TOKEN_ARG"
  else
    echo ""
    echo "  Necesitas un token de instalacion para vincular tu Mac."
    echo "  Lo puedes obtener en: https://prophunt-app.netlify.app/dashboard"
    echo "  (Menu: Configuracion → Generar token)"
    echo ""
    read -p "  Token de instalacion: " SETUP_TOKEN < /dev/tty
  fi

  if [[ -z "$SETUP_TOKEN" ]]; then
    echo ""
    echo "  No se introdujo token. Puedes configurar manualmente despues."
    echo "  Ejecuta: $INSTALL_DIR/scripts/setup-auth.sh"
  else
    # Validate token via Supabase RPC
    echo "  Validando token..."
    VALIDATION=$(curl -s "$SB_URL/rest/v1/rpc/validate_setup_token" \
      -H "apikey: $SB_ANON_KEY" \
      -H "Authorization: Bearer $SB_ANON_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"setup_token\": \"$SETUP_TOKEN\"}")

    VALID=$(echo "$VALIDATION" | jq -r '.valid // false')

    if [[ "$VALID" != "true" ]]; then
      ERROR_MSG=$(echo "$VALIDATION" | jq -r '.error // "Token invalido"')
      echo "  Token invalido: $ERROR_MSG"
      echo "  Genera uno nuevo desde el dashboard y ejecuta: $INSTALL_DIR/scripts/setup-auth.sh"
    else
      USER_EMAIL=$(echo "$VALIDATION" | jq -r '.email')
      echo "  Token valido para: $USER_EMAIL"
      echo ""
      read -sp "  Contrasena de $USER_EMAIL: " USER_PASSWORD < /dev/tty
      echo ""

      # Validate password via Supabase Auth
      AUTH_RESULT=$(curl -s "$SB_URL/auth/v1/token?grant_type=password" \
        -H "apikey: $SB_ANON_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$USER_EMAIL\", \"password\": \"$USER_PASSWORD\"}")

      if echo "$AUTH_RESULT" | jq -e '.access_token' > /dev/null 2>&1; then
        echo "  Autenticacion OK"
        # Write .env with credentials
        cat > .env <<ENVEOF
IDEALISTA_API_KEY=
IDEALISTA_SECRET=

# Supabase (configurado automaticamente)
SUPABASE_URL=$SB_URL
SUPABASE_ANON_KEY=$SB_ANON_KEY
PROPHUNT_EMAIL=$USER_EMAIL
PROPHUNT_PASSWORD=$USER_PASSWORD
ENVEOF
        echo "  .env configurado automaticamente"
      else
        echo "  Contrasena incorrecta. Puedes configurar despues: $INSTALL_DIR/scripts/setup-auth.sh"
      fi
    fi
  fi
fi

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   Instalacion completada!            ║"
echo "  ╚══════════════════════════════════════╝"
echo ""
echo "  Ubicacion: $INSTALL_DIR"
echo ""
echo "  Pasos pendientes:"
echo ""
echo "  1. Instalar extension Claude en Chrome:"
echo "     https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn"
echo ""
echo "  2. Loguearte en los portales inmobiliarios en Chrome:"
echo "     idealista.com, fotocasa.es, pisos.com"
echo "     (necesario para poder ver telefonos de vendedores)"
echo ""
echo "  El sistema se ejecutara automaticamente cada dia."
echo "  Para probarlo manualmente: cd $INSTALL_DIR && ./run.sh test"
echo ""
