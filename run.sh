#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
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

if [[ -z "$MODE" ]]; then
  echo "Uso:"
  echo "  ./run.sh test [+34XXXXXXXXX]  Prueba completa (Gmail→Chrome→WhatsApp a tel de test)"
  echo "  ./run.sh dashboard [--dry-run] Dashboard web en http://localhost:3456"
  echo "  ./run.sh api [--dry-run]      Buscar via API Idealista"
  echo "  ./run.sh email <archivo.eml>  Procesar email de BetterPlace"
  echo "  cat email.eml | ./run.sh email"
  echo "  ./run.sh server [--dry-run]   Servidor HTTP puente (Chrome ext ↔ wacli)"
  echo "  ./run.sh betterplace          Desatendido: Gmail → Chrome → WhatsApp"
  exit 1
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
    echo "         Instalar: brew install steipete/tap/wacli" | tee -a "$LOG"
    PREFLIGHT_OK=false
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
  echo "IMPORTANTE: Asegurate de que en Chrome:" | tee -a "$LOG"
  echo "  1. La extension de Claude esta activa (icono Claude en la barra de extensiones)" | tee -a "$LOG"
  echo "  2. Gmail esta abierto en una pestana con al menos un email de Idealista" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
  read -p "Pulsa Enter cuando este listo para continuar..."
  echo "" | tee -a "$LOG"
  echo "Lanzando test..." | tee -a "$LOG"
  echo "" | tee -a "$LOG"

  # Leer plantilla de WhatsApp
  WHATSAPP_TEMPLATE=""
  if [[ -f "$DIR/templates/whatsapp.txt" ]]; then
    WHATSAPP_TEMPLATE=$(cat "$DIR/templates/whatsapp.txt")
  fi

  # Temp files for Claude to write results
  TEST_MSG_FILE="/tmp/prophunt_test_message.txt"
  TEST_DATA_FILE="/tmp/prophunt_test_data.json"
  rm -f "$TEST_MSG_FILE" "$TEST_DATA_FILE"

  # Write prompt to temp file to avoid quoting issues
  PROMPT_FILE=$(mktemp /tmp/prophunt_test_prompt.XXXXXX)
  cat > "$PROMPT_FILE" <<PROMPT_EOF
Eres un agente de captacion inmobiliaria automatizado para Juanan Gomis (REMAX Experience, Palma de Mallorca).

MODO TEST: Vas a hacer el ciclo completo de captacion PERO SIN ENVIAR el WhatsApp. Solo preparas todo y guardas el resultado en archivos temporales.

PASO 1: BUSCAR EMAIL DE IDEALISTA EN GMAIL
- Usa tabs_context_mcp para obtener las pestanas abiertas en Chrome
- Gmail ya deberia estar abierto. Encuentralo
- Busca: from:idealista (o similar, un email reciente con un link a un inmueble)
- Si no hay ningun email de Idealista, busca cualquier email que contenga un link a idealista.com
- Abre el email mas reciente que tenga un link a idealista

PASO 2: ABRIR EL INMUEBLE
- Del email, extrae el link a idealista.com
- Abre ese link en una nueva pestana
- Espera a que cargue completamente

PASO 3: LEER LA FICHA DEL INMUEBLE
- Lee TODOS los detalles de la ficha:
  - Direccion / zona
  - Precio
  - Metros cuadrados
  - Numero de habitaciones y banos
  - Planta
  - Caracteristicas destacadas (terraza, ascensor, reformado, vistas, garaje, etc.)
  - Tipo de inmueble (piso, casa, atico, duplex, etc.)
  - Nombre del anunciante si aparece
- Registra todos estos datos, los necesitas para personalizar el mensaje

PASO 4: VER EL TELEFONO (solo para verificar que funciona)
- Busca el boton Ver telefono o Contactar y haz click
- Extrae el numero que aparece
- Registra el numero REAL en los datos

PASO 5: CONSTRUIR MENSAJE PERSONALIZADO
- Usa la plantilla base:
$WHATSAPP_TEMPLATE

- Reemplaza los campos:
  - {{nombre}} -> nombre del anunciante si lo hay, si no quitar esa parte (cambiar Hola nombre soy por Hola soy)
  - {{tipo}} -> tipo de inmueble (piso, casa, atico, etc.)
  - {{zona}} -> direccion o zona del inmueble
  - {{portal}} -> idealista
  - {{precio}} -> precio formateado (ej: 350.000 euros)
  - {{detalle}} -> genera UNA frase natural y corta (max 20 palabras) mencionando algo especifico y positivo de la ficha. Ejemplos:
    Los 85 m2 con terraza y esas vistas al parque tienen muy buena pinta
    Un atico de 3 habitaciones con esa orientacion sur es dificil de encontrar
    La reforma reciente y la ubicacion junto al centro lo hacen muy atractivo
    NO seas generico. Menciona algo CONCRETO de la ficha.

PASO 6: GUARDAR RESULTADOS (NO ENVIAR WHATSAPP)
- Guarda el mensaje construido en $TEST_MSG_FILE (solo el texto del mensaje, nada mas)
- Guarda los datos del inmueble en $TEST_DATA_FILE como JSON:
  {"name": "nombre o null", "url": "url", "portal": "idealista", "zone": "zona", "price": precio, "phone_real": "telefono extraido de la ficha"}

NO envies ningun WhatsApp. Solo guarda los archivos.

Directorio de trabajo: $DIR
PROMPT_EOF

  # Ask user: betterplace (Gmail) or direct URL?
  echo "Como quieres probar?" | tee -a "$LOG"
  echo "  1) BetterPlace (buscar email de Idealista en Gmail)" | tee -a "$LOG"
  echo "  2) URL directa de un anuncio de Idealista" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
  read -p "Opcion (1 o 2): " TEST_OPTION
  TEST_OPTION="${TEST_OPTION:-1}"

  # Phone override for test mode
  TEST_PHONE_OVERRIDE="${2:-34619458478}"
  TEST_PHONE_OVERRIDE="${TEST_PHONE_OVERRIDE#+}"
  if [[ ! "$TEST_PHONE_OVERRIDE" == 34* ]]; then
    TEST_PHONE_OVERRIDE="34$TEST_PHONE_OVERRIDE"
  fi

  echo "Lanzando servidor y pipeline de test..." | tee -a "$LOG"

  SERVER_PORT=$(jq -r '.server.port // 3456' config.json)

  # Kill any existing server on this port
  lsof -ti:$SERVER_PORT 2>/dev/null | xargs kill 2>/dev/null || true
  sleep 1

  # Launch server in background for test
  $SERVER_CMD &
  TEST_SERVER_PID=$!
  sleep 3

  if [[ "$TEST_OPTION" == "2" ]]; then
    # Direct URL mode
    read -p "Pega la URL del anuncio de Idealista: " DIRECT_URL
    if [[ -z "$DIRECT_URL" ]]; then
      DIRECT_URL="https://www.idealista.com/inmueble/88686391/"
    fi
    echo "Navegando a: $DIRECT_URL" | tee -a "$LOG"
    echo "Telefono de test: $TEST_PHONE_OVERRIDE" | tee -a "$LOG"
    curl -s -X POST "http://127.0.0.1:$SERVER_PORT/api/run-direct" \
      -H "Content-Type: application/json" \
      -d "{\"url\": \"$DIRECT_URL\", \"portal\": \"idealista\", \"phone_override\": \"$TEST_PHONE_OVERRIDE\"}" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
  else
    # BetterPlace (Gmail) mode
    curl -s -X POST "http://127.0.0.1:$SERVER_PORT/api/run-betterplace" >/dev/null 2>&1
  fi

  # Wait up to 5 min for pipeline to finish (use /pipeline/status, NOT /browser/next-task)
  for i in $(seq 1 60); do
    sleep 5
    STATUS_JSON=$(curl -s "http://127.0.0.1:$SERVER_PORT/pipeline/status" 2>/dev/null)
    PIPELINE_DONE=$(echo "$STATUS_JSON" | jq -r '.done // false' 2>/dev/null)
    PIPELINE_STATE=$(echo "$STATUS_JSON" | jq -r '.state // "unknown"' 2>/dev/null)
    QUEUE_PENDING=$(echo "$STATUS_JSON" | jq -r '.queue_pending // 0' 2>/dev/null)
    echo "  Pipeline: $PIPELINE_STATE | Cola: $QUEUE_PENDING pendientes" | tee -a "$LOG"
    if [[ "$PIPELINE_DONE" == "true" && "$QUEUE_PENDING" == "0" ]]; then break; fi
  done

  # Shutdown test server
  curl -s -X POST "http://127.0.0.1:$SERVER_PORT/shutdown" >/dev/null 2>&1 || true
  wait $TEST_SERVER_PID 2>/dev/null || true

  rm -f "$PROMPT_FILE"

  if [[ "$TEST_OPTION" == "2" ]]; then
    # Direct URL mode — pipeline handled everything (extract phone, build message, send WhatsApp)
    echo "" | tee -a "$LOG"
    echo "═══════════════════════════════════════════" | tee -a "$LOG"
    echo "  RESULTADO DEL TEST (URL directa)" | tee -a "$LOG"
    echo "═══════════════════════════════════════════" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "URL: $DIRECT_URL" | tee -a "$LOG"
    echo "Telefono de envio: $TEST_PHONE_OVERRIDE" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "El pipeline ha procesado el inmueble automaticamente." | tee -a "$LOG"
    echo "Revisa el log del dia: data/logs/$DATE.log" | tee -a "$LOG"
    echo "Y contacted.json para ver el registro." | tee -a "$LOG"
  else
    # BetterPlace mode — check Claude temp files
    # Check if Claude produced the message file
    if [[ ! -f "$TEST_MSG_FILE" ]]; then
      echo "" | tee -a "$LOG"
      echo "ERROR: No se pudo generar el mensaje. Revisa los logs." | tee -a "$LOG"
      echo ""
      echo "Pulsa Enter para cerrar"; read
      exit 1
    fi

    # Show results to user
    echo "" | tee -a "$LOG"
    echo "═══════════════════════════════════════════" | tee -a "$LOG"
    echo "  RESULTADO DEL TEST" | tee -a "$LOG"
    echo "═══════════════════════════════════════════" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    if [[ -f "$TEST_DATA_FILE" ]]; then
      echo "Inmueble: $(jq -r '.zone // "?"' "$TEST_DATA_FILE")" | tee -a "$LOG"
      echo "Precio:   $(jq -r '.price // "?"' "$TEST_DATA_FILE")" | tee -a "$LOG"
      echo "Portal:   $(jq -r '.portal // "?"' "$TEST_DATA_FILE")" | tee -a "$LOG"
      echo "URL:      $(jq -r '.url // "?"' "$TEST_DATA_FILE")" | tee -a "$LOG"
      PHONE_REAL=$(jq -r '.phone_real // "no extraido"' "$TEST_DATA_FILE")
      echo "Tel real: $PHONE_REAL" | tee -a "$LOG"
    fi

    echo "" | tee -a "$LOG"
    echo "--- Mensaje WhatsApp ---" | tee -a "$LOG"
    cat "$TEST_MSG_FILE" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "------------------------" | tee -a "$LOG"
    echo ""

    # Ask for phone number
    read -p "Telefono al que enviar el test (Enter = 34629659757, 'n' = cancelar): " TEST_PHONE
    if [[ "$TEST_PHONE" == "n" || "$TEST_PHONE" == "N" ]]; then
      echo "Envio cancelado." | tee -a "$LOG"
      rm -f "$TEST_MSG_FILE" "$TEST_DATA_FILE"
      echo ""
      echo "Pulsa Enter para cerrar"; read
      exit 0
    fi
    TEST_PHONE="${TEST_PHONE:-34629659757}"
    # Strip leading +
    TEST_PHONE="${TEST_PHONE#+}"
    # Ensure 34 prefix
    if [[ ! "$TEST_PHONE" == 34* ]]; then
      TEST_PHONE="34$TEST_PHONE"
    fi

    echo "" | tee -a "$LOG"
    echo "Enviando WhatsApp a $TEST_PHONE..." | tee -a "$LOG"

    MSG_CONTENT=$(cat "$TEST_MSG_FILE")
    if wacli send text --to "$TEST_PHONE" --message "$MSG_CONTENT" 2>&1 | tee -a "$LOG"; then
      echo "WhatsApp enviado OK" | tee -a "$LOG"
      SEND_STATUS="test"
    else
      echo "ERROR al enviar WhatsApp" | tee -a "$LOG"
      SEND_STATUS="test_failed"
    fi

    # Register in contacted.json
    if [[ -f "$TEST_DATA_FILE" ]]; then
      CONTACT_NAME=$(jq -r '.name // ""' "$TEST_DATA_FILE")
      CONTACT_URL=$(jq -r '.url // ""' "$TEST_DATA_FILE")
      CONTACT_ZONE=$(jq -r '.zone // ""' "$TEST_DATA_FILE")
      CONTACT_PRICE=$(jq -r '.price // 0' "$TEST_DATA_FILE")
      CONTACT_PHONE_REAL=$(jq -r '.phone_real // ""' "$TEST_DATA_FILE")

      # Add to contacted.json using jq
      TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S")
      MSG_PREVIEW=$(head -c 100 "$TEST_MSG_FILE")
      jq --arg phone "$TEST_PHONE" \
         --arg name "$CONTACT_NAME" \
         --arg url "$CONTACT_URL" \
         --arg zone "$CONTACT_ZONE" \
         --argjson price "$CONTACT_PRICE" \
         --arg date "$TIMESTAMP" \
         --arg status "$SEND_STATUS" \
         --arg preview "$MSG_PREVIEW" \
         --arg notes "TEST: telefono real del anuncio era $CONTACT_PHONE_REAL. Enviado a $TEST_PHONE" \
         '.contacts += [{"phone":$phone,"name":$name,"url":$url,"portal":"idealista","zone":$zone,"price":$price,"date_contacted":$date,"status":$status,"message_preview":$preview,"notes":$notes}]' \
         data/contacted.json > data/contacted_tmp.json && mv data/contacted_tmp.json data/contacted.json

      echo "Contacto registrado en contacted.json" | tee -a "$LOG"
    fi

    rm -f "$TEST_MSG_FILE" "$TEST_DATA_FILE"
  fi

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
#  MODO BETTERPLACE — Desatendido (Gmail → Chrome Extension → WhatsApp)
# ═══════════════════════════════════════════
elif [[ "$MODE" == "betterplace" ]]; then
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
  echo "Usa: ./run.sh test | dashboard | api | email | server | betterplace" | tee -a "$LOG"
  exit 1
fi
