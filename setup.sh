#!/bin/bash
set -e

echo "🏠 AI PropHunt — Setup"
echo "======================"
echo ""

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
  echo "❌ Este script es solo para macOS"
  exit 1
fi

# 1. Install wacli
echo "📱 Instalando wacli..."
if command -v wacli &> /dev/null; then
  echo "  ✅ wacli ya instalado ($(wacli --version 2>/dev/null || echo 'ok'))"
else
  if command -v brew &> /dev/null; then
    brew install steipete/tap/wacli
    echo "  ✅ wacli instalado"
  else
    echo "  ❌ Necesitas Homebrew. Instálalo primero: https://brew.sh"
    exit 1
  fi
fi

# 2. Check Claude Code
echo ""
echo "🤖 Verificando Claude Code..."
if command -v claude &> /dev/null; then
  echo "  ✅ Claude Code instalado"
else
  echo "  ❌ Claude Code no encontrado."
  echo "  Instálalo desde: https://docs.anthropic.com/en/docs/claude-code"
  echo "  O ejecuta: npm install -g @anthropic-ai/claude-code"
  exit 1
fi

# 3. Check jq
echo ""
echo "📦 Verificando jq..."
if command -v jq &> /dev/null; then
  echo "  ✅ jq instalado"
else
  brew install jq
  echo "  ✅ jq instalado"
fi

# 4. Create data directories + config
echo ""
echo "📁 Creando directorios y configuracion..."
mkdir -p data/logs
if [[ ! -f data/contacted.json ]]; then
  echo '{"contacts":[]}' > data/contacted.json
  echo "  ✅ data/contacted.json creado"
else
  echo "  ✅ data/contacted.json ya existe"
fi

if [[ ! -f config.json ]]; then
  if [[ -f config.example.json ]]; then
    cp config.example.json config.json
    echo "  ✅ config.json creado desde config.example.json"
  else
    echo "  ❌ config.example.json no encontrado"
    exit 1
  fi
else
  echo "  ✅ config.json ya existe"
fi

# 5. Auth wacli
echo ""
echo "📱 Configurar WhatsApp..."
echo "  Ejecuta: wacli auth"
echo "  Escanea el QR con el WhatsApp de Juanan"
echo ""
read -p "  ¿Quieres autenticar wacli ahora? (s/n): " auth_now
if [[ "$auth_now" == "s" ]]; then
  wacli auth
fi

# 6. Portal login reminder
echo ""
echo "🌐 IMPORTANTE — Login en portales inmobiliarios:"
echo "  Abre Chrome y asegurate de estar logueado en:"
echo "  - https://www.idealista.com"
echo "  - https://www.fotocasa.es"
echo "  - https://www.pisos.com"
echo "  (necesario para poder ver telefonos de vendedores)"
echo ""
echo "  Instala la extension de Chrome de Claude Code:"
echo "  https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn"

# 7. Make scripts executable
chmod +x run.sh scripts/*.sh 2>/dev/null || true

echo ""
echo "✅ Setup completo!"
echo ""
echo "Proximos pasos:"
echo "  1. Autenticar wacli (si no lo has hecho): wacli auth"
echo "  2. Loguearte en los portales en Chrome (idealista, fotocasa, pisos.com)"
echo "  3. Instalar extension Claude en Chrome:"
echo "     https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn"
echo ""
echo "El sistema se ejecutara automaticamente cada dia."
echo "Para probarlo: ./run.sh test"
echo "Dashboard web: https://prophunt-app.netlify.app/dashboard"
