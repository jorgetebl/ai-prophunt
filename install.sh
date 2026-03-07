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

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   AI PropHunt — Instalador           ║"
echo "  ║   REMAX Experience                   ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# Parse args
GH_TOKEN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) GH_TOKEN="$2"; shift 2 ;;
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── macOS check ──
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Este instalador es solo para macOS."
  exit 1
fi

# ── Homebrew ──
echo "[1/7] Homebrew..."
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
echo "[2/7] Node.js..."
if command -v node &>/dev/null; then
  echo "       Ya instalado ($(node -v))"
else
  echo "       Instalando..."
  brew install node
fi

# ── jq ──
echo "[3/7] jq..."
if command -v jq &>/dev/null; then
  echo "       Ya instalado"
else
  brew install jq
fi

# ── Claude Code CLI ──
echo "[4/7] Claude Code CLI..."
if command -v claude &>/dev/null; then
  echo "       Ya instalado"
else
  echo "       Instalando..."
  npm install -g @anthropic-ai/claude-code
fi

# ── wacli ──
echo "[5/7] wacli (WhatsApp CLI)..."
if command -v wacli &>/dev/null; then
  echo "       Ya instalado"
else
  echo "       Instalando..."
  brew install steipete/tap/wacli
fi

# ── Descargar proyecto ──
echo "[6/7] Descargando AI PropHunt..."
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

# ── Configurar ──
echo "[7/7] Configurando..."
chmod +x run.sh setup.sh scripts/*.sh 2>/dev/null || true
mkdir -p data/logs

if [[ ! -f config.json ]] && [[ -f config.example.json ]]; then
  cp config.example.json config.json
fi

if [[ ! -f data/contacted.json ]]; then
  echo '{"contacts":[]}' > data/contacted.json
fi

if [[ ! -f .env ]]; then
  cat > .env <<'ENVEOF'
IDEALISTA_API_KEY=
IDEALISTA_SECRET=

# Supabase
SUPABASE_URL=
SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
PROPHUNT_EMAIL=
PROPHUNT_PASSWORD=
ENVEOF
  echo "       Creado .env — rellena las credenciales de Supabase"
fi

npm install --silent 2>/dev/null || true

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
echo "     https://chromewebstore.google.com/detail/claude/danfoalhlfigljpbflibpbpnpoafglcl"
echo ""
echo "  2. Vincular WhatsApp (escanear QR):"
echo "     wacli auth"
echo ""
echo "  3. Loguearte en los portales inmobiliarios en Chrome:"
echo "     idealista.com, fotocasa.es, pisos.com"
echo "     (necesario para poder ver telefonos de vendedores)"
echo ""
echo "  4. Configurar Supabase en .env:"
echo "     Abre $INSTALL_DIR/.env y rellena SUPABASE_URL,"
echo "     SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, PROPHUNT_EMAIL y PROPHUNT_PASSWORD"
echo ""
echo "  El sistema se ejecutara automaticamente cada dia."
echo "  Para probarlo manualmente: cd $INSTALL_DIR && ./run.sh test"
echo ""
