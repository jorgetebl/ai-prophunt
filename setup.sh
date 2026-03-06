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
echo "🌐 IMPORTANTE — Login en portales:"
echo "  Abre Chrome y asegúrate de estar logueado en:"
echo "  1. https://www.idealista.com (cuenta de Juanan)"
echo "  2. https://www.fotocasa.es (cuenta de Juanan)"  
echo "  3. https://www.pisos.com (cuenta de Juanan)"
echo ""
echo "  También instala la extensión de Chrome de Claude Code si no la tienes."

# 7. Make scripts executable
chmod +x run.sh scripts/*.sh 2>/dev/null || true

echo ""
echo "✅ Setup completo!"
echo ""
echo "Próximos pasos:"
echo "  1. Autenticar wacli (si no lo has hecho): wacli auth"
echo "  2. Loguearte en los portales en Chrome"
echo "  3. Instalar extensión de Chrome de Claude Code"
echo "  4. Probar: ./run.sh test"
echo "  5. Dashboard: ./run.sh dashboard"
echo "  6. Automatizar: ./scripts/install_cron.sh"
echo ""
echo "El software se actualiza automaticamente cada vez que se ejecuta."
echo "Para desactivar: pon \"auto_update\": false en config.json"
