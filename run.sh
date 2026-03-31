#!/bin/bash
set -e

DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")")" && pwd)"
cd "$DIR"

# Si node no está en el PATH, usar la ruta guardada por el instalador
if ! command -v node &>/dev/null; then
  SAVED_NODE="$(cat "$HOME/.prophunt/node_bin" 2>/dev/null)"
  if [[ -n "$SAVED_NODE" && -x "$SAVED_NODE" ]]; then
    export PATH="$(dirname "$SAVED_NODE"):$PATH"
  fi
fi

DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M)
LOG="data/logs/$DATE.log"
mkdir -p data/logs

echo "ai-prophunt — $DATE $TIME" | tee -a "$LOG"

# ─────────────────────────────────────────────
# Detectar entorno: desarrollo (src/) vs instalado (server.bundle.cjs)
# ─────────────────────────────────────────────
if [[ -f "$DIR/src/server.js" ]]; then
  SERVER_CMD="node src/server.js"
elif [[ -f "$DIR/server.bundle.cjs" ]]; then
  SERVER_CMD="node server.bundle.cjs"
else
  echo "ERROR: No se encuentra el servidor (ni src/server.js ni server.bundle.cjs)" | tee -a "$LOG"
  exit 1
fi

# ─────────────────────────────────────────────
# Auto-update desde repo remoto (si hay)
# ─────────────────────────────────────────────
if [[ "${PROPHUNT_NO_UPDATE:-}" != "1" && -f "$DIR/scripts/update.sh" ]]; then
  bash "$DIR/scripts/update.sh" || UPDATE_EXIT=$?
  UPDATE_EXIT=${UPDATE_EXIT:-0}
  if [[ "$UPDATE_EXIT" -eq 42 ]]; then
    echo "Re-ejecutando con version actualizada..." | tee -a "$LOG"
    PROPHUNT_NO_UPDATE=1 exec "$DIR/run.sh" "$@"
  fi
fi

# ─────────────────────────────────────────────
# Modo de uso:
#   ./run.sh api              → Busca via API Idealista + Claude Code procesa
#   ./run.sh api --dry-run    → Igual pero sin enviar WhatsApp
#   ./run.sh email <archivo>  → Modo BetterPlace (email) original
#   cat email.eml | ./run.sh email  → Modo email desde stdin
#   ./run.sh server           → Lanza servidor HTTP puente (Chrome ext ↔ wacli)
#   ./run.sh server --dry-run → Servidor en modo simulación
#   ./run.sh betterplace      → Desatendido: Gmail → parsear → Chrome → WhatsApp
# ─────────────────────────────────────────────

MODE="${1:-}"

if [[ "$MODE" == "--version" || "$MODE" == "-v" || "$MODE" == "version" ]]; then
  VERSION=$(node -p "require('$DIR/package.json').version" 2>/dev/null || grep '"version"' "$DIR/package.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
  echo "prophunt v${VERSION:-?}"
  exit 0
fi

if [[ -z "$MODE" || "$MODE" == "--help" || "$MODE" == "-h" || "$MODE" == "help" ]]; then
  echo ""
  echo "  ai-prophunt — captación inmobiliaria automatizada"
  echo ""
  echo "  Uso: ./run.sh <comando> [opciones]"
  echo "       prophunt <comando> [opciones]   (si está instalado en PATH)"
  echo ""
  echo "  Comandos principales:"
  echo ""
  echo "    run [--dry-run]          Ejecuta el pipeline UNA VEZ ahora mismo:"
  echo "                             busca email de BetterPlace de hoy → navega"
  echo "                             cada anuncio en Chrome → extrae teléfono →"
  echo "                             envía WhatsApp. Ideal para pruebas manuales"
  echo "                             o cuando el ordenador estuvo apagado."
  echo ""
  echo "    start [--dry-run]        Arranca el servidor en modo daemon (se queda"
  echo "                             corriendo). Ejecuta automáticamente a las 9:00"
  echo "                             de lunes a viernes, y también cuando detecta"
  echo "                             un email nuevo de alertas@betterplaceapp.com."
  echo "                             Con --dry-run simula envíos sin usar WhatsApp."
  echo ""
  echo "    test [+34XXXXXXXXX]      Prueba completa: Gmail → Chrome → WhatsApp."
  echo "                             Pasa un teléfono para enviar el mensaje de prueba."
  echo ""
  echo "    dashboard [--dry-run]    Igual que start pero abre el dashboard web"
  echo "                             en http://localhost:3456 al arrancar."
  echo ""
  echo "  Instalar comando 'prophunt':"
  echo "    sudo ln -sf \$PWD/run.sh /usr/local/bin/prophunt"
  echo "    prophunt run    # ejecutar una vez"
  echo "    prophunt start  # arrancar daemon"
  echo ""
  echo "  Opciones globales:"
  echo "    -h, --help               Muestra esta ayuda."
  echo "    --version                Muestra la versión."
  echo ""
  [[ -z "$MODE" ]] && exit 1 || exit 0
fi

# ═══════════════════════════════════════════
#  MODO DASHBOARD — Web UI
# ═══════════════════════════════════════════
if [[ "$MODE" == "dashboard" ]]; then
  DRY_RUN_FLAG=""
  if [[ "$2" == "--dry-run" ]]; then
    DRY_RUN_FLAG="--dry-run"
  fi

  SERVER_PORT=$(jq -r '.server.port // 3456' config.json)
  echo "Modo: Dashboard web $DRY_RUN_FLAG" | tee -a "$LOG"
  echo "Abriendo http://localhost:$SERVER_PORT ..." | tee -a "$LOG"

  # Open browser after a short delay
  (sleep 1 && open "http://localhost:$SERVER_PORT") &

  $SERVER_CMD --dashboard $DRY_RUN_FLAG 2>&1 | tee -a "$LOG"
  exit 0
fi

# Pre-checks comunes
TODAY_COUNT=$(jq "[.contacts[] | select(.date_contacted | startswith(\"$DATE\"))] | length" data/contacted.json 2>/dev/null || echo 0)
MAX_PER_DAY=$(jq -r '.filters.max_contacts_per_day' config.json)

echo "Contactos hoy: $TODAY_COUNT / $MAX_PER_DAY (limite de envio controlado por servidor)" | tee -a "$LOG"

# ═══════════════════════════════════════════
#  MODO TEST — Ciclo completo con teléfono de prueba
# ═══════════════════════════════════════════
if [[ "$MODE" == "test" ]]; then
  echo "Modo: TEST (ciclo completo con confirmacion)" | tee -a "$LOG"

  # ── Pre-flight checks ──
  echo "" | tee -a "$LOG"
  echo "Verificando requisitos..." | tee -a "$LOG"
  PREFLIGHT_OK=true

  # 1. ANTHROPIC_API_KEY configurada
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    # Try to load from .env
    ANTHROPIC_API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$DIR/.env" 2>/dev/null | cut -d= -f2-)
  fi
  if [[ -n "$ANTHROPIC_API_KEY" ]]; then
    echo "  OK    ANTHROPIC_API_KEY configurada" | tee -a "$LOG"
  else
    echo "  FAIL  ANTHROPIC_API_KEY no configurada" | tee -a "$LOG"
    echo "         Añadir en .env: ANTHROPIC_API_KEY=sk-ant-..." | tee -a "$LOG"
    PREFLIGHT_OK=false
  fi

  # 2. Node.js y servidor
  if command -v node &>/dev/null; then
    echo "  OK    Node.js $(node --version)" | tee -a "$LOG"
  else
    echo "  FAIL  Node.js no instalado" | tee -a "$LOG"
    PREFLIGHT_OK=false
  fi

  # 3. Chrome corriendo
  if pgrep -x "Google Chrome" >/dev/null 2>&1 || pgrep -f "Google Chrome" >/dev/null 2>&1; then
    echo "  OK    Chrome corriendo" | tee -a "$LOG"
  else
    echo "  FAIL  Chrome no esta abierto" | tee -a "$LOG"
    echo "         Abre Chrome con Gmail logueado" | tee -a "$LOG"
    PREFLIGHT_OK=false
  fi

  # 4. Extension AI PropHunt en Chrome (directorio del proyecto)
  PROPHUNT_EXT_DIR="$DIR/chrome-extension"
  if [[ -d "$PROPHUNT_EXT_DIR" && -f "$PROPHUNT_EXT_DIR/manifest.json" ]]; then
    echo "  OK    Extension AI PropHunt disponible en $PROPHUNT_EXT_DIR" | tee -a "$LOG"
    echo "         (Asegurate de haberla cargado en Chrome Developer Mode)" | tee -a "$LOG"
  else
    echo "  FAIL  Extension AI PropHunt no encontrada en $PROPHUNT_EXT_DIR" | tee -a "$LOG"
    PREFLIGHT_OK=false
  fi

  # 5. wacli
  if command -v wacli &>/dev/null; then
    if wacli doctor 2>&1 | grep -qi "connected\|authenticated\|ok"; then
      echo "  OK    wacli conectado" | tee -a "$LOG"
    else
      echo "  WARN  wacli instalado pero puede no estar autenticado" | tee -a "$LOG"
      echo "         Verificar: wacli doctor" | tee -a "$LOG"
    fi
  else
    echo "  FAIL  wacli no instalado" | tee -a "$LOG"
    echo "         Instalando wacli..." | tee -a "$LOG"
    if brew install steipete/tap/wacli 2>&1 | tail -1 | tee -a "$LOG"; then
      echo "  OK    wacli instalado" | tee -a "$LOG"
    else
      echo "         Instalar manualmente: brew install steipete/tap/wacli" | tee -a "$LOG"
      PREFLIGHT_OK=false
    fi
  fi

  # 6. gogcli (Google CLI para acceso a Gmail)
  if command -v gogcli &>/dev/null; then
    echo "  OK    gogcli instalado" | tee -a "$LOG"
  else
    echo "  FAIL  gogcli no instalado" | tee -a "$LOG"
    echo "         Instalando gogcli..." | tee -a "$LOG"
    if brew install steipete/tap/gogcli 2>&1 | tail -1 | tee -a "$LOG"; then
      echo "  OK    gogcli instalado" | tee -a "$LOG"
    else
      echo "         Instalar manualmente: brew install steipete/tap/gogcli" | tee -a "$LOG"
      PREFLIGHT_OK=false
    fi
  fi

  echo "" | tee -a "$LOG"

  if [[ "$PREFLIGHT_OK" != "true" ]]; then
    echo "Hay problemas que resolver antes de ejecutar el test." | tee -a "$LOG"
    echo "Corrige los FAIL de arriba e intentalo de nuevo." | tee -a "$LOG"
    echo ""
    echo "Pulsa Enter para cerrar"; read
    exit 1
  fi

  echo "Todo OK." | tee -a "$LOG"
  echo "" | tee -a "$LOG"
  echo "IMPORTANTE: Chrome debe tener la extension AI PropHunt activa." | tee -a "$LOG"
  echo "" | tee -a "$LOG"

  # ── Teléfono de prueba ──────────────────────────────────────────────────────
  DEFAULT_TEST_PHONE="${2:-34619458478}"
  DEFAULT_TEST_PHONE="${DEFAULT_TEST_PHONE#+}"
  [[ ! "$DEFAULT_TEST_PHONE" == 34* ]] && DEFAULT_TEST_PHONE="34$DEFAULT_TEST_PHONE"

  read -p "Teléfono al que enviar el WhatsApp de prueba (Enter = $DEFAULT_TEST_PHONE): " TEST_PHONE
  TEST_PHONE="${TEST_PHONE:-$DEFAULT_TEST_PHONE}"
  TEST_PHONE="${TEST_PHONE#+}"
  [[ ! "$TEST_PHONE" == 34* ]] && TEST_PHONE="34$TEST_PHONE"
  echo "WhatsApp de prueba se enviará a: $TEST_PHONE" | tee -a "$LOG"
  echo "" | tee -a "$LOG"

  # ── Modo del test ───────────────────────────────────────────────────────────
  echo "¿Qué quieres probar?" | tee -a "$LOG"
  echo "  1) BetterPlace: busca email en Gmail → abre inmueble → extrae teléfono → WhatsApp" | tee -a "$LOG"
  echo "  2) URL directa: pega la URL de un anuncio y prueba el ciclo completo" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
  read -p "Opción (1 o 2, Enter = 1): " TEST_OPTION
  TEST_OPTION="${TEST_OPTION:-1}"

  SERVER_PORT=$(jq -r '.server.port // 3456' config.json)

  # Matar servidor previo en este puerto si hubiera uno
  lsof -ti:$SERVER_PORT 2>/dev/null | xargs kill 2>/dev/null || true
  sleep 1

  # Lanzar servidor en background para el test
  echo "" | tee -a "$LOG"
  echo "Lanzando servidor de test en puerto $SERVER_PORT..." | tee -a "$LOG"
  $SERVER_CMD &
  TEST_SERVER_PID=$!
  for i in $(seq 1 15); do
    if curl -s "http://127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then break; fi
    sleep 1
  done

  if ! curl -s "http://127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then
    echo "ERROR: El servidor no arrancó en 15 segundos. Revisa los logs." | tee -a "$LOG"
    echo "Pulsa Enter para cerrar"; read
    exit 1
  fi
  echo "Servidor listo. Esperando extensión Chrome (4s)..." | tee -a "$LOG"
  sleep 4

  # ── Lanzar pipeline ─────────────────────────────────────────────────────────
  if [[ "$TEST_OPTION" == "2" ]]; then
    read -p "URL del anuncio (Enter = https://www.idealista.com/inmueble/88686391/): " DIRECT_URL
    DIRECT_URL="${DIRECT_URL:-https://www.idealista.com/inmueble/88686391/}"
    echo "Navegando a: $DIRECT_URL" | tee -a "$LOG"
    echo "Teléfono de test: $TEST_PHONE" | tee -a "$LOG"
    curl -s -X POST "http://127.0.0.1:$SERVER_PORT/api/run-direct" \
      -H "Content-Type: application/json" \
      -d "{\"url\": \"$DIRECT_URL\", \"portal\": \"idealista\", \"phone_override\": \"$TEST_PHONE\"}" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
  else
    echo "Iniciando pipeline BetterPlace con teléfono de prueba..." | tee -a "$LOG"
    curl -s -X POST "http://127.0.0.1:$SERVER_PORT/api/run-betterplace" \
      -H "Content-Type: application/json" \
      -d "{\"phone_override\": \"$TEST_PHONE\"}" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
  fi

  # ── Esperar a que el pipeline y la cola terminen (máx 10 min) ───────────────
  echo "Esperando resultados..." | tee -a "$LOG"
  for i in $(seq 1 120); do
    sleep 5
    STATUS_JSON=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" 2>/dev/null)
    PIPELINE_DONE=$(echo "$STATUS_JSON" | jq -r '.done // false' 2>/dev/null)
    PIPELINE_STATE=$(echo "$STATUS_JSON" | jq -r '.state // "unknown"' 2>/dev/null)
    QUEUE_PENDING=$(echo "$STATUS_JSON" | jq -r '.queue_pending // 0' 2>/dev/null)
    if (( i % 3 == 0 )); then
      echo "  Estado: $PIPELINE_STATE | Cola: $QUEUE_PENDING pendientes" | tee -a "$LOG"
    fi
    if [[ "$PIPELINE_DONE" == "true" && "$QUEUE_PENDING" == "0" ]]; then break; fi
  done

  # ── Apagar servidor de test ─────────────────────────────────────────────────
  curl -s -X POST "http://127.0.0.1:$SERVER_PORT/shutdown" >/dev/null 2>&1 || true
  wait $TEST_SERVER_PID 2>/dev/null || true

  # ── Resultado ───────────────────────────────────────────────────────────────
  echo "" | tee -a "$LOG"
  echo "═══════════════════════════════════════════" | tee -a "$LOG"
  echo "  RESULTADO DEL TEST" | tee -a "$LOG"
  echo "═══════════════════════════════════════════" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
  echo "  WhatsApp enviado a: $TEST_PHONE" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
  # Mostrar los últimos contactos registrados (los del test, últimos 5 min)
  TEST_SINCE=$(date -u -v-5M +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || date -u --date='5 minutes ago' +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")
  if [[ -n "$TEST_SINCE" && -f data/contacted.json ]]; then
    echo "  Contactos registrados en este test:" | tee -a "$LOG"
    jq -r --arg since "$TEST_SINCE" \
      '.contacts[] | select(.date_contacted >= $since) | "    \(.status) | \(.zone // .url // "-") | tel enviado: \(.phone)"' \
      data/contacted.json 2>/dev/null | tee -a "$LOG" || echo "    (sin registros)" | tee -a "$LOG"
  fi
  echo "" | tee -a "$LOG"
  echo "  Log completo: data/logs/$DATE.log" | tee -a "$LOG"
  echo "  Registro:     data/contacted.json" | tee -a "$LOG"

  echo "" | tee -a "$LOG"
  echo "Run TEST completado — $DATE $(date +%H:%M)" | tee -a "$LOG"
  echo ""
  echo "Pulsa Enter para cerrar"; read

# ═══════════════════════════════════════════
#  MODO API — Idealista API + Claude Code
# ═══════════════════════════════════════════
elif [[ "$MODE" == "api" ]]; then
  DRY_RUN_FLAG=""
  DRY_RUN_MSG=""
  if [[ "$2" == "--dry-run" ]]; then
    DRY_RUN_FLAG="--dry-run"
    DRY_RUN_MSG="MODO DRY RUN: No enviar WhatsApp, solo simular."
  fi

  if [[ -n "$DRY_RUN_FLAG" ]]; then
    echo "  (modo simulacion — no se enviaran WhatsApps)" | tee -a "$LOG"
  fi
  echo "" | tee -a "$LOG"

  # ── Paso 1: Buscar inmuebles en Idealista ──
  echo "Buscando inmuebles nuevos en Idealista..." | tee -a "$LOG"
  if [[ -f "$DIR/src/index.js" ]]; then
    node src/index.js >> "$LOG" 2>&1
  elif [[ -f "$DIR/search.bundle.cjs" ]]; then
    node search.bundle.cjs >> "$LOG" 2>&1
  else
    echo "  Error: no se encuentra el modulo de busqueda" | tee -a "$LOG"
    exit 1
  fi

  # Verificar resultados
  PENDING_COUNT=$(jq '.properties | length' data/pending.json 2>/dev/null || echo 0)
  TOTAL_FOUND=$(jq '.stats.totalFound // 0' data/pending.json 2>/dev/null || echo 0)
  PARTICULARES=$(jq '.stats.particulares // 0' data/pending.json 2>/dev/null || echo 0)
  DUPLICATES=$(jq '.stats.duplicates // 0' data/pending.json 2>/dev/null || echo 0)

  echo "  Encontrados: $TOTAL_FOUND inmuebles en Idealista" | tee -a "$LOG"
  if [[ "$PARTICULARES" -gt 0 ]]; then
    echo "  Particulares: $PARTICULARES (descartadas agencias)" | tee -a "$LOG"
  fi
  if [[ "$DUPLICATES" -gt 0 ]]; then
    echo "  Ya contactados: $DUPLICATES (no se repiten)" | tee -a "$LOG"
  fi
  echo "  Nuevos para revisar: $PENDING_COUNT" | tee -a "$LOG"

  if [[ "$PENDING_COUNT" -eq 0 ]]; then
    echo "" | tee -a "$LOG"
    echo "No hay inmuebles nuevos que procesar hoy." | tee -a "$LOG"
    exit 0
  fi

  echo "" | tee -a "$LOG"

  # ── Paso 2: Conectar con el servidor ──
  SERVER_PORT=$(jq -r '.server.port // 3456' config.json)

  if curl -s "http://127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then
    echo "Servidor conectado." | tee -a "$LOG"
    SERVER_ALREADY_RUNNING=true
    SERVER_PID=""
  else
    echo "Arrancando servidor..." | tee -a "$LOG"
    $SERVER_CMD $DRY_RUN_FLAG >> "$LOG" 2>&1 &
    SERVER_PID=$!
    SERVER_ALREADY_RUNNING=false

    for i in $(seq 1 10); do
      if curl -s "http://127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then break; fi
      sleep 1
    done

    if ! curl -s "http://127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then
      echo "  Error: el servidor no arranco. Revisa los logs." | tee -a "$LOG"
      exit 1
    fi
    echo "Servidor listo." | tee -a "$LOG"
  fi

  echo "" | tee -a "$LOG"
  echo "Revisando $PENDING_COUNT inmuebles uno a uno..." | tee -a "$LOG"
  echo "(Abro cada ficha en Chrome, busco el telefono y si es particular le escribo por WhatsApp)" | tee -a "$LOG"
  echo "" | tee -a "$LOG"

  # ── Paso 3: Procesar cada inmueble ──
  PROCESSED=0
  PHONES_FOUND=0
  MESSAGES_SENT=0
  NO_PHONE=0
  ERRORS=0

  for i in $(seq 0 $((PENDING_COUNT - 1))); do
    PROP_URL=$(jq -r ".properties[$i].url" data/pending.json)
    PROP_ZONE=$(jq -r ".properties[$i].zone // .properties[$i].address // \"\"" data/pending.json)
    PROP_PRICE=$(jq -r ".properties[$i].price // 0" data/pending.json)
    PROP_PRICE_FMT=$(printf "%'.0f" "$PROP_PRICE" 2>/dev/null || echo "$PROP_PRICE")
    PROP_PORTAL=$(jq -r ".properties[$i].portal // \"idealista\"" data/pending.json)

    PROCESSED=$((PROCESSED + 1))

    # Mostrar info del inmueble
    if [[ -n "$PROP_ZONE" && "$PROP_ZONE" != "null" ]]; then
      echo "[$PROCESSED/$PENDING_COUNT] $PROP_ZONE — ${PROP_PRICE_FMT} €" | tee -a "$LOG"
    else
      echo "[$PROCESSED/$PENDING_COUNT] Inmueble en $PROP_PORTAL — ${PROP_PRICE_FMT} €" | tee -a "$LOG"
    fi

    # Esperar a que el pipeline este libre
    for w in $(seq 1 60); do
      PIPE_STATE=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" | jq -r '.done // false' 2>/dev/null)
      if [[ "$PIPE_STATE" == "true" ]]; then break; fi
      sleep 3
    done

    # Enviar al pipeline
    RESPONSE=$(curl -s -X POST "http://127.0.0.1:$SERVER_PORT/api/run-direct" \
      -H "Content-Type: application/json" \
      -d "{\"url\": \"$PROP_URL\", \"portal\": \"$PROP_PORTAL\", \"zone\": \"$PROP_ZONE\", \"price\": $PROP_PRICE}")

    RESPONSE_OK=$(echo "$RESPONSE" | jq -r '.ok // false' 2>/dev/null)
    if [[ "$RESPONSE_OK" != "true" ]]; then
      RESP_ERROR=$(echo "$RESPONSE" | jq -r '.error // "unknown"' 2>/dev/null)
      echo "  ✗ No se pudo procesar: $RESP_ERROR" | tee -a "$LOG"
      ERRORS=$((ERRORS + 1))
      continue
    fi

    echo "  Abriendo ficha en Chrome..." | tee -a "$LOG"

    # Esperar a que termine (max 3 min)
    LAST_STATE=""
    for j in $(seq 1 36); do
      sleep 5
      STATUS_JSON=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" 2>/dev/null)
      PIPELINE_DONE=$(echo "$STATUS_JSON" | jq -r '.done // false' 2>/dev/null)
      PIPELINE_STATE=$(echo "$STATUS_JSON" | jq -r '.state // "unknown"' 2>/dev/null)

      # Mostrar progreso de forma natural
      if [[ "$PIPELINE_STATE" != "$LAST_STATE" ]]; then
        case "$PIPELINE_STATE" in
          DOM_PENDING|DOM_RECEIVED|PROCESSING)
            [[ "$LAST_STATE" != "reading" ]] && echo "  Leyendo la ficha del inmueble..." | tee -a "$LOG" && LAST_STATE="reading"
            ;;
          CLICKING|CLICKING_WAITING|DOM_PENDING_2)
            [[ "$LAST_STATE" != "clicking" ]] && echo "  Buscando el telefono..." | tee -a "$LOG" && LAST_STATE="clicking"
            ;;
          PHONE_FOUND)
            echo "  Telefono encontrado, preparando mensaje..." | tee -a "$LOG"
            LAST_STATE="$PIPELINE_STATE"
            ;;
          DONE|IDLE)
            break
            ;;
          *)
            LAST_STATE="$PIPELINE_STATE"
            ;;
        esac
      fi

      if [[ "$PIPELINE_DONE" == "true" ]]; then break; fi
    done

    # Comprobar resultado
    if [[ "$PIPELINE_DONE" != "true" ]]; then
      echo "  ✗ Tiempo agotado, paso al siguiente" | tee -a "$LOG"
      ERRORS=$((ERRORS + 1))
    fi

    # Comprobar resultado leyendo el ultimo log del servidor
    QUEUE_SENT_NOW=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" | jq -r '.queue_sent // 0' 2>/dev/null)
    QUEUE_PENDING=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" | jq -r '.queue_pending // 0' 2>/dev/null)
    LAST_LOG_LINE=$(tail -5 "$LOG" 2>/dev/null | grep -i "Pipeline" | tail -1)

    if [[ "$QUEUE_PENDING" -gt 0 || "$QUEUE_SENT_NOW" -gt "$MESSAGES_SENT" ]]; then
      PHONES_FOUND=$((PHONES_FOUND + 1))
      echo "  ✓ Telefono encontrado — WhatsApp enviado" | tee -a "$LOG"
      MESSAGES_SENT=$QUEUE_SENT_NOW
    elif echo "$LAST_LOG_LINE" | grep -qi "agency"; then
      SKIPPED=$((SKIPPED + 1))
      echo "  ✗ Es una agencia (detectada en la ficha)" | tee -a "$LOG"
    elif echo "$LAST_LOG_LINE" | grep -qi "landline"; then
      SKIPPED=$((SKIPPED + 1))
      echo "  ✗ Telefono fijo (probablemente agencia)" | tee -a "$LOG"
    elif echo "$LAST_LOG_LINE" | grep -qi "duplicate"; then
      SKIPPED=$((SKIPPED + 1))
      echo "  — Ya contactado anteriormente" | tee -a "$LOG"
    else
      NO_PHONE=$((NO_PHONE + 1))
      echo "  — No se encontro telefono" | tee -a "$LOG"
    fi

    echo "" | tee -a "$LOG"

    # Pausa entre inmuebles
    if [[ $PROCESSED -lt $PENDING_COUNT ]]; then
      sleep 3
    fi
  done

  # ── Paso 4: Esperar a que se envien todos los WhatsApps pendientes ──
  QUEUE_PENDING=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" | jq -r '.queue_pending // 0' 2>/dev/null)
  if [[ "$QUEUE_PENDING" -gt 0 ]]; then
    echo "Enviando los ultimos $QUEUE_PENDING WhatsApps..." | tee -a "$LOG"
    for i in $(seq 1 120); do
      QUEUE_PENDING=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" | jq -r '.queue_pending // 0' 2>/dev/null)
      if [[ "$QUEUE_PENDING" -eq 0 ]]; then break; fi
      sleep 5
    done
  fi

  FINAL_SENT=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" | jq -r '.queue_sent // 0' 2>/dev/null)

  # ── Resumen final ──
  echo "═══════════════════════════════════════" | tee -a "$LOG"
  echo "  Resumen del dia" | tee -a "$LOG"
  echo "═══════════════════════════════════════" | tee -a "$LOG"
  echo "  Inmuebles revisados:   $PROCESSED" | tee -a "$LOG"
  echo "  Telefonos encontrados: $PHONES_FOUND" | tee -a "$LOG"
  echo "  WhatsApps enviados:    $FINAL_SENT" | tee -a "$LOG"
  if [[ "$SKIPPED" -gt 0 ]]; then
    echo "  Agencias/fijos:        $SKIPPED (descartados)" | tee -a "$LOG"
  fi
  echo "  Sin telefono:          $NO_PHONE" | tee -a "$LOG"
  if [[ "$ERRORS" -gt 0 ]]; then
    echo "  Errores:               $ERRORS" | tee -a "$LOG"
  fi
  echo "═══════════════════════════════════════" | tee -a "$LOG"

  # Apagar servidor (solo si lo arrancamos nosotros)
  if [[ "$SERVER_ALREADY_RUNNING" == "false" && -n "$SERVER_PID" ]]; then
    curl -s -X POST "http://127.0.0.1:$SERVER_PORT/shutdown" >/dev/null 2>&1 || true
    wait $SERVER_PID 2>/dev/null || true
  fi

  echo "" | tee -a "$LOG"
  echo "Listo — $(date +%H:%M)" | tee -a "$LOG"

# ═══════════════════════════════════════════
#  MODO EMAIL — BetterPlace (flujo original)
# ═══════════════════════════════════════════
elif [[ "$MODE" == "email" ]]; then
  echo "Modo: Email BetterPlace" | tee -a "$LOG"

  # Leer contenido del email
  EMAIL_CONTENT=""
  if [[ -n "$2" && -f "$2" ]]; then
    EMAIL_CONTENT=$(cat "$2")
    echo "Email loaded from file: $2" | tee -a "$LOG"
  elif [[ ! -t 0 ]]; then
    EMAIL_CONTENT=$(cat)
    echo "Email loaded from stdin" | tee -a "$LOG"
  else
    echo "Error: Modo email requiere archivo o stdin" | tee -a "$LOG"
    echo "  ./run.sh email <archivo.eml>" | tee -a "$LOG"
    echo "  cat email.eml | ./run.sh email" | tee -a "$LOG"
    exit 1
  fi

  # Guardar email en temp
  TEMP_EMAIL="/tmp/prophunt_email_$DATE.txt"
  echo "$EMAIL_CONTENT" > "$TEMP_EMAIL"

  echo "Lanzando Claude Code para procesar email..." | tee -a "$LOG"

  claude --print \
    "Lee el archivo $TEMP_EMAIL que contiene un email de BetterPlace con inmuebles de particulares.

Sigue estas instrucciones paso a paso:

1. PARSEAR el email y extraer los links de inmuebles de PARTICULARES solamente.
   Cada bloque tiene: titulo, precio, m2, habs, portal, y links.
   Extrae: URL del inmueble (Ficha del inmueble), zona, portal, precio.

2. Para CADA inmueble de particular:
   a. NAVEGAR a la URL usando la extension de Chrome
   b. EXTRAER el telefono del vendedor:
      - Idealista: buscar 'Contactar' o 'Ver telefono', click, extraer numero
      - Fotocasa: buscar 'Ver telefono', click, extraer numero
      - Pisos.com: buscar boton de contacto/telefono, click, extraer
   c. SOLO contactar si el numero empieza por 6 o 7 (moviles)
   d. Si hay captcha, error, o no se puede extraer → SKIP y continuar

3. VERIFICAR DUPLICADOS en data/contacted.json:
   - Si el telefono ya fue contactado → SKIP
   - Si la URL ya fue procesada → SKIP

4. ENVIAR WhatsApp usando wacli:
   wacli send --to \"34XXXXXXXXX\" --message \"<mensaje>\"
   - Usar plantilla de templates/whatsapp.txt
   - Reemplazar {{nombre}}, {{zona}}, {{portal}}

5. REGISTRAR en data/contacted.json y data/logs/$DATE.log

REGLAS:
- Esperar MINIMO 2 minutos entre cada envio de WhatsApp
- Esperar 5-10 segundos entre cada navegacion
- Maximo $SLOTS_LEFT contactos mas hoy
- No contactar agencias, solo particulares
- Si detectas captcha o bloqueo, PARA y pasa al siguiente
- No reintentar mas de 3 veces por inmueble
- Horario valido: 9:00-14:00 y 16:00-20:00 (hora Madrid)

Directorio de trabajo: $DIR" 2>&1 | tee -a "$LOG"

  echo "" | tee -a "$LOG"
  echo "Run email completado — $DATE $(date +%H:%M)" | tee -a "$LOG"

# ═══════════════════════════════════════════
#  MODO SERVER — Servidor HTTP puente
# ═══════════════════════════════════════════
elif [[ "$MODE" == "server" ]]; then
  DRY_RUN_FLAG=""
  if [[ "$2" == "--dry-run" ]]; then
    DRY_RUN_FLAG="--dry-run"
  fi

  echo "Modo: Server HTTP puente $DRY_RUN_FLAG" | tee -a "$LOG"

  SERVER_PORT=$(jq -r '.server.port // 3456' config.json)

  echo "Lanzando servidor en puerto $SERVER_PORT..." | tee -a "$LOG"
  $SERVER_CMD $DRY_RUN_FLAG 2>&1 | tee -a "$LOG"

# ═══════════════════════════════════════════
#  MODO START — Daemon (servidor + scheduler + email watcher)
# ═══════════════════════════════════════════
elif [[ "$MODE" == "start" ]]; then
  DRY_RUN_FLAG=""
  if [[ "$2" == "--dry-run" ]]; then
    DRY_RUN_FLAG="--dry-run"
  fi

  echo ""
  echo "  ¿En qué modo quieres arrancar el servidor?"
  echo ""
  echo "    1) Diario a las 9:00           (ejecuta el pipeline una vez al día, L-V)"
  echo "    2) Vigilancia cada 30 min      (revisa Gmail cada 30 min, solo emails nuevos)"
  echo "    3) Ambos  [recomendado]        (9:00 diario + vigilancia 30 min)"
  echo ""
  read -p "  Modo (1-3, Enter = 3): " START_MODE_OPT
  START_MODE_OPT="${START_MODE_OPT:-3}"

  case "$START_MODE_OPT" in
    1) SCHEDULE_MODE_FLAG="--schedule-mode=daily"
       SCHEDULE_MODE_DESC="Diario a las 9:00 (L-V)" ;;
    2) SCHEDULE_MODE_FLAG="--schedule-mode=watch"
       SCHEDULE_MODE_DESC="Vigilancia de Gmail cada 30 min" ;;
    *)  SCHEDULE_MODE_FLAG="--schedule-mode=both"
       SCHEDULE_MODE_DESC="Ambos: 9:00 diario + vigilancia 30 min" ;;
  esac

  echo ""
  echo "Modo: $SCHEDULE_MODE_DESC $DRY_RUN_FLAG" | tee -a "$LOG"

  SERVER_PORT=$(jq -r '.server.port // 3456' config.json)
  echo "Lanzando servidor en puerto $SERVER_PORT..." | tee -a "$LOG"
  $SERVER_CMD $DRY_RUN_FLAG $SCHEDULE_MODE_FLAG 2>&1 | tee -a "$LOG"

# ═══════════════════════════════════════════
#  MODO RUN / BETTERPLACE — Ejecutar una vez ahora
# ═══════════════════════════════════════════
elif [[ "$MODE" == "run" || "$MODE" == "betterplace" ]]; then
  echo "Modo: BetterPlace desatendido (Gmail → Chrome Extension → WhatsApp)" | tee -a "$LOG"

  SERVER_PORT=$(jq -r '.server.port // 3456' config.json)

  # Comprobar si el servidor ya está corriendo
  if curl -s "http://127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then
    echo "Servidor ya en ejecución en puerto $SERVER_PORT" | tee -a "$LOG"
    SERVER_ALREADY_RUNNING=true
  else
    echo "Lanzando servidor Node en puerto $SERVER_PORT..." | tee -a "$LOG"
    $SERVER_CMD &
    SERVER_PID=$!
    SERVER_ALREADY_RUNNING=false

    # Esperar a que el servidor esté listo (máx 15s)
    for i in $(seq 1 15); do
      if curl -s "http://127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then
        echo "Servidor listo (PID $SERVER_PID)" | tee -a "$LOG"
        break
      fi
      sleep 1
    done

    if ! curl -s "http://127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then
      echo "ERROR: El servidor no arrancó en 15 segundos. Abortando." | tee -a "$LOG"
      exit 1
    fi
  fi

  # Verificar que la extensión de Chrome está conectada
  echo "Verificando extensión Chrome..." | tee -a "$LOG"
  # La extensión ya hace polling al servidor. Esperamos 5s para asegurar la primera conexión.
  sleep 5

  # Disparar el pipeline BetterPlace
  echo "Iniciando pipeline BetterPlace..." | tee -a "$LOG"
  PIPELINE_RESPONSE=$(curl -s -X POST "http://127.0.0.1:$SERVER_PORT/api/run-betterplace" \
    -H "Content-Type: application/json")
  echo "Pipeline: $PIPELINE_RESPONSE" | tee -a "$LOG"

  # Esperar a que el pipeline termine (máx 30 min)
  # IMPORTANT: use /pipeline/status instead of /browser/next-task to avoid
  # interfering with the Chrome extension's polling of next-task
  echo "Esperando a que el pipeline termine..." | tee -a "$LOG"
  for i in $(seq 1 360); do
    PDONE=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" | jq -r '.done // "false"' 2>/dev/null)
    PSTATE=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" | jq -r '.state // "unknown"' 2>/dev/null)
    if [[ "$PDONE" == "true" ]]; then
      PRESULTS=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" | jq -r '.results // 0' 2>/dev/null)
      echo "Pipeline terminado (estado: $PSTATE, resultados: $PRESULTS)" | tee -a "$LOG"
      break
    fi
    # Show progress every 30s (every 6 iterations)
    if (( i % 6 == 0 )); then
      echo "  ... pipeline en estado: $PSTATE" | tee -a "$LOG"
    fi
    sleep 5
  done

  echo "" | tee -a "$LOG"
  echo "Run BetterPlace completado — $DATE $(date +%H:%M)" | tee -a "$LOG"

  # Apagar servidor si lo lanzamos nosotros
  if [[ "$SERVER_ALREADY_RUNNING" == "false" && -n "${SERVER_PID:-}" ]]; then
    echo "Apagando servidor..." | tee -a "$LOG"
    curl -s -X POST "http://127.0.0.1:$SERVER_PORT/shutdown" >/dev/null 2>&1 || true
    wait $SERVER_PID 2>/dev/null || true
  fi

else
  echo "Modo desconocido: $MODE" | tee -a "$LOG"
  echo "Usa: ./run.sh run | start | test | dashboard" | tee -a "$LOG"
  echo "     ./run.sh --help para ver toda la ayuda" | tee -a "$LOG"
  exit 1
fi
