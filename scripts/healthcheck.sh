#!/bin/bash
# Health check para ai-prophunt
# Verifica que todo esta listo para la ejecucion automatica

DIR="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

check() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "  OK  $name"
  else
    echo "  FAIL  $name"
    ERRORS=$((ERRORS + 1))
  fi
}

echo "AI PropHunt — Health Check"
echo "=========================="
echo ""

# 1. wacli instalado y accesible
check "wacli instalado" "command -v wacli"

# 2. wacli autenticado (doctor check)
check "wacli autenticado" "wacli doctor 2>&1 | grep -qi 'connected\|authenticated\|ok'"

# 3. claude CLI instalado
check "claude CLI instalado" "command -v claude"

# 4. node instalado
check "node instalado" "command -v node"

# 5. jq instalado
check "jq instalado" "command -v jq"

# 6. Chrome esta corriendo
check "Chrome corriendo" "pgrep -x 'Google Chrome' || pgrep -f 'Google Chrome'"

# 7. Archivos de datos existen
check "data/contacted.json existe" "test -f $DIR/data/contacted.json"
check "templates/whatsapp.txt existe" "test -f $DIR/templates/whatsapp.txt"
check "config.json existe" "test -f $DIR/config.json"

# 8. Directorio de logs escribible
mkdir -p "$DIR/data/logs" 2>/dev/null
check "data/logs/ escribible" "test -w $DIR/data/logs"

# 9. Espacio en disco (minimo 1GB libre)
FREE_KB=$(df -k "$DIR" | tail -1 | awk '{print $4}')
check "Espacio en disco (>1GB)" "test $FREE_KB -gt 1048576"

# 10. launchd job registrado
check "launchd job registrado" "launchctl list 2>/dev/null | grep -q prophunt"

# 11. pmset wake configurado
check "pmset wake configurado" "pmset -g sched 2>/dev/null | grep -qi 'wake\|poweron'"

echo ""
if [[ $ERRORS -eq 0 ]]; then
  echo "Todo OK — listo para ejecucion automatica"
else
  echo "$ERRORS problema(s) detectado(s) — revisar antes de activar"
fi

exit $ERRORS
