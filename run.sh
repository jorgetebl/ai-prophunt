#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M)
LOG="data/logs/$DATE.log"
mkdir -p data/logs

echo "ai-prophunt — $DATE $TIME" | tee -a "$LOG"

# ─────────────────────────────────────────────
# Auto-update desde repo remoto (si hay)
# ─────────────────────────────────────────────
if [[ "${PROPHUNT_NO_UPDATE:-}" != "1" ]]; then
  bash "$DIR/scripts/update.sh" || UPDATE_EXIT=$?
  UPDATE_EXIT=${UPDATE_EXIT:-0}
  if [[ "$UPDATE_EXIT" -eq 42 ]]; then
    # run.sh fue actualizado, re-ejecutar con la nueva version
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

  node src/server.js --dashboard $DRY_RUN_FLAG 2>&1 | tee -a "$LOG"
  exit 0
fi

# Pre-checks comunes
TODAY_COUNT=$(jq "[.contacts[] | select(.date_contacted | startswith(\"$DATE\"))] | length" data/contacted.json 2>/dev/null || echo 0)
MAX_PER_DAY=$(jq -r '.filters.max_contacts_per_day' config.json)
SLOTS_LEFT=$((MAX_PER_DAY - TODAY_COUNT))

echo "Contactos hoy: $TODAY_COUNT / $MAX_PER_DAY" | tee -a "$LOG"

if [[ "$TODAY_COUNT" -ge "$MAX_PER_DAY" ]]; then
  echo "Limite diario alcanzado. Abortando." | tee -a "$LOG"
  exit 0
fi

# ═══════════════════════════════════════════
#  MODO TEST — Ciclo completo con teléfono de prueba
# ═══════════════════════════════════════════
if [[ "$MODE" == "test" ]]; then
  TEST_PHONE="${2:-34629659757}"
  # Strip leading + if present
  TEST_PHONE="${TEST_PHONE#+}"

  echo "Modo: TEST (ciclo completo → WhatsApp a $TEST_PHONE)" | tee -a "$LOG"

  # Leer plantilla de WhatsApp
  WHATSAPP_TEMPLATE=""
  if [[ -f "$DIR/templates/whatsapp.txt" ]]; then
    WHATSAPP_TEMPLATE=$(cat "$DIR/templates/whatsapp.txt")
  fi

  claude --print --chrome --dangerously-skip-permissions \
    --allowedTools "Bash(read:*) Bash(wacli:*) Bash(jq:*) Bash(date:*) Bash(mkdir:*) mcp__claude-in-chrome__*" \
    "Eres un agente de captación inmobiliaria automatizado para Juanan Gomis (REMAX Experience, Palma de Mallorca).

MODO TEST: Vas a hacer UN ciclo completo de prueba. El WhatsApp se envía al número de test $TEST_PHONE (NO al teléfono real del anuncio).

PASO 1: BUSCAR EMAIL DE IDEALISTA EN GMAIL
- Usa tabs_context_mcp para obtener las pestañas abiertas en Chrome
- Gmail ya debería estar abierto. Encuéntralo
- Busca: from:idealista (o similar — un email reciente con un link a un inmueble)
- Si no hay ningún email de Idealista, busca cualquier email que contenga un link a idealista.com
- Abre el email más reciente que tenga un link a idealista

PASO 2: ABRIR EL INMUEBLE
- Del email, extrae el link a idealista.com
- Abre ese link en una nueva pestaña
- Espera a que cargue completamente

PASO 3: LEER LA FICHA DEL INMUEBLE
- Lee TODOS los detalles de la ficha:
  - Dirección / zona
  - Precio
  - Metros cuadrados
  - Número de habitaciones y baños
  - Planta
  - Características destacadas (terraza, ascensor, reformado, vistas, garaje, etc.)
  - Tipo de inmueble (piso, casa, ático, dúplex, etc.)
  - Nombre del anunciante si aparece
- Registra todos estos datos, los necesitas para personalizar el mensaje

PASO 4: VER EL TELÉFONO (solo para verificar que funciona)
- Busca el botón 'Ver teléfono' o 'Contactar' y haz click
- Extrae el número que aparece
- Registra el número REAL pero NO lo uses para el envío (es una prueba)

PASO 5: CONSTRUIR MENSAJE PERSONALIZADO
- Usa la plantilla base:
$WHATSAPP_TEMPLATE

- Reemplaza los campos:
  - {{nombre}} → nombre del anunciante si lo hay, si no quitar esa parte (cambiar 'Hola {{nombre}}, soy' por 'Hola, soy')
  - {{tipo}} → tipo de inmueble (piso, casa, ático, etc.)
  - {{zona}} → dirección o zona del inmueble
  - {{portal}} → idealista
  - {{precio}} → precio formateado (ej: '350.000 €')
  - {{detalle}} → genera UNA frase natural y corta (máx 20 palabras) mencionando algo específico y positivo de la ficha. Ejemplos:
    'Los 85 m² con terraza y esas vistas al parque tienen muy buena pinta'
    'Un ático de 3 habitaciones con esa orientación sur es difícil de encontrar'
    'La reforma reciente y la ubicación junto al centro lo hacen muy atractivo'
    NO seas genérico. Menciona algo CONCRETO de la ficha.

PASO 6: ENVIAR WHATSAPP AL NÚMERO DE TEST
- Comando: wacli send text --to '$TEST_PHONE' --message '<mensaje construido>'
- IMPORTANTE: enviar al $TEST_PHONE, NO al teléfono de la ficha

PASO 7: REGISTRAR
- Actualizar $DIR/data/contacted.json:
  {
    \"phone\": \"$TEST_PHONE\",
    \"name\": \"<nombre o null>\",
    \"url\": \"<url del inmueble>\",
    \"portal\": \"idealista\",
    \"zone\": \"<zona>\",
    \"price\": <precio>,
    \"date_contacted\": \"<ISO timestamp>\",
    \"status\": \"test\",
    \"message_preview\": \"<primeros 100 chars del mensaje>\",
    \"notes\": \"TEST: teléfono real del anuncio era <tel_real>. Enviado a $TEST_PHONE\"
  }
- Escribir log en $DIR/data/logs/$DATE.log con timestamp para cada acción
- Al terminar, escribir resumen

Directorio de trabajo: $DIR" 2>&1 | tee -a "$LOG"

  echo "" | tee -a "$LOG"
  echo "Run TEST completado — $DATE $(date +%H:%M)" | tee -a "$LOG"

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

  echo "Modo: API Idealista $DRY_RUN_FLAG" | tee -a "$LOG"

  # Paso 1: Node.js busca en la API, filtra y genera data/pending.json
  echo "Buscando inmuebles via API..." | tee -a "$LOG"
  node src/index.js 2>&1 | tee -a "$LOG"

  # Verificar que hay inmuebles pendientes
  PENDING_COUNT=$(jq '.properties | length' data/pending.json 2>/dev/null || echo 0)

  if [[ "$PENDING_COUNT" -eq 0 ]]; then
    echo "No hay inmuebles nuevos que procesar." | tee -a "$LOG"
    exit 0
  fi

  echo "$PENDING_COUNT inmuebles pendientes. Lanzando Claude Code..." | tee -a "$LOG"

  # Paso 2: Lanzar servidor HTTP puente en background
  SERVER_PORT=$(jq -r '.server.port // 3456' config.json)
  node src/server.js $DRY_RUN_FLAG &
  SERVER_PID=$!
  echo "Servidor puente lanzado (PID $SERVER_PID, puerto $SERVER_PORT)" | tee -a "$LOG"

  # Esperar a que el servidor esté listo
  for i in $(seq 1 10); do
    if curl -s "http://127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then
      echo "Servidor listo en puerto $SERVER_PORT" | tee -a "$LOG"
      break
    fi
    sleep 1
  done

  # Paso 3: Claude Code procesa cada inmueble con Chrome extension + wacli
  claude --print \
    "Lee el archivo data/pending.json que contiene $PENDING_COUNT inmuebles de particulares obtenidos de la API de Idealista.

$DRY_RUN_MSG

Para CADA inmueble en el array 'properties':

1. NAVEGAR a la URL del inmueble usando la extension de Chrome
2. VERIFICAR que es un particular:
   - Mirar la zona de contacto/anunciante
   - Si aparece logo de agencia, nombre de inmobiliaria, o cualquier indicador profesional → SKIP, registrar como 'skipped_agency_detected'
3. EXTRAER el telefono:
   - Buscar y hacer click en 'Ver telefono' o boton similar
   - Extraer el numero que aparece
   - SOLO contactar si el numero empieza por 6 o 7 (moviles españoles)
   - Si es fijo (empieza por 9, 8, etc.) → SKIP, registrar como 'skipped_landline'
   - Si hay captcha o error → SKIP, registrar como 'skipped_captcha'
4. ENVIAR WhatsApp usando wacli:
   wacli send --to \"34XXXXXXXXX\" --message \"<mensaje>\"
   - Usar la plantilla de templates/whatsapp.txt
   - Reemplazar {{zona}} con la direccion del inmueble
   - Reemplazar {{portal}} con 'idealista'
   - Si no hay nombre del vendedor, cambiar 'Hola {{nombre}}, soy' por 'Hola, soy'
5. REGISTRAR en data/contacted.json con formato:
   {
     \"phone\": \"34XXXXXXXXX\",
     \"name\": null,
     \"url\": \"<url del inmueble>\",
     \"propertyCode\": \"<codigo>\",
     \"portal\": \"idealista\",
     \"zone\": \"<direccion>\",
     \"price\": <precio>,
     \"date_contacted\": \"<ISO timestamp>\",
     \"status\": \"sent\" o \"skipped_<razon>\",
     \"message_preview\": \"<primeros 100 chars del mensaje>\"
   }

REGLAS:
- Esperar MINIMO 2 minutos entre cada envio de WhatsApp
- Esperar 5-10 segundos entre cada navegacion a un inmueble
- Maximo $SLOTS_LEFT contactos mas hoy
- Si detectas captcha o bloqueo, PARA y pasa al siguiente
- No reintentar mas de 3 veces por inmueble
- Horario valido: 9:00-14:00 y 16:00-20:00 (hora Madrid)
- Registrar TODAS las acciones en data/logs/$DATE.log con timestamp

Directorio de trabajo: $DIR" 2>&1 | tee -a "$LOG"

  # Paso 4: Apagar servidor puente
  echo "Apagando servidor puente..." | tee -a "$LOG"
  curl -s -X POST "http://127.0.0.1:$SERVER_PORT/shutdown" >/dev/null 2>&1 || true
  wait $SERVER_PID 2>/dev/null || true

  echo "" | tee -a "$LOG"
  echo "Run API completado — $DATE $(date +%H:%M)" | tee -a "$LOG"

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
  node src/server.js $DRY_RUN_FLAG 2>&1 | tee -a "$LOG"

# ═══════════════════════════════════════════
#  MODO BETTERPLACE — Desatendido (Gmail → Chrome → WhatsApp)
# ═══════════════════════════════════════════
elif [[ "$MODE" == "betterplace" ]]; then
  echo "Modo: BetterPlace desatendido (Gmail → Chrome → WhatsApp)" | tee -a "$LOG"

  # Leer plantilla de WhatsApp
  WHATSAPP_TEMPLATE=""
  if [[ -f "$DIR/templates/whatsapp.txt" ]]; then
    WHATSAPP_TEMPLATE=$(cat "$DIR/templates/whatsapp.txt")
  fi

  claude --print --chrome --dangerously-skip-permissions \
    --allowedTools "Bash(read:*) Bash(wacli:*) Bash(jq:*) Bash(date:*) Bash(mkdir:*) mcp__claude-in-chrome__*" \
    "Eres un agente de captación inmobiliaria automatizado para Juanan Gomis (REMAX Experience, Palma de Mallorca).
Ejecuta el flujo completo SIN intervención humana.

PASO 1: BUSCAR EMAIL EN GMAIL
- Usa tabs_context_mcp para obtener las pestañas abiertas en Chrome
- Gmail ya está abierto en una pestaña. Encuéntrala
- Navega a Gmail y busca: from:betterplace OR from:noreply@betterplace
- Si no hay email de hoy ($DATE), registra en el log y termina
- Si hay email, ábrelo y lee su contenido

PASO 2: PARSEAR EL EMAIL
- Extrae bloques de inmuebles del email de BetterPlace
- Cada bloque tiene: título, precio, m², habs, portal, links
- SOLO procesar los que digan 'Particular' (ignorar agencias)
- De cada bloque extraer:
  - URL del inmueble (link 'Ficha del inmueble' o link del portal)
  - Zona/dirección (del título)
  - Portal (idealista, fotocasa, pisos.com, etc.)
  - Precio

PASO 3: PARA CADA INMUEBLE DE PARTICULAR
a) Abrir la URL del inmueble en Chrome (crear nueva pestaña)
b) Esperar 5-10 segundos para que cargue
c) Buscar botón 'Ver teléfono' o 'Contactar' y hacer click
d) Extraer el número de teléfono que aparece
e) Validar que empieza por 6 o 7 (móviles españoles)
   - Si es fijo (empieza por 9, 8, etc.) → SKIP, registrar como 'skipped_landline'
   - Si es profesional/agencia → SKIP, registrar como 'skipped_agency'
   - Si hay captcha o error → SKIP, registrar como 'skipped_captcha'
   - No reintentar más de 3 veces por inmueble

PASO 4: VERIFICAR DUPLICADOS
- Leer $DIR/data/contacted.json
- Si el teléfono ya fue contactado → SKIP
- Si la URL ya fue procesada → SKIP

PASO 5: ENVIAR WHATSAPP
- Comando: wacli send text --to '34XXXXXXXXX' --message '<mensaje>'
- Plantilla del mensaje:
$WHATSAPP_TEMPLATE
- Reemplazar {{nombre}} con nombre del vendedor si está disponible, si no quitar esa parte
  (cambiar 'Hola {{nombre}}, soy' por 'Hola, soy')
- Reemplazar {{zona}} con la dirección/zona del inmueble
- Reemplazar {{portal}} con el nombre del portal
- ESPERAR MÍNIMO 2 MINUTOS entre cada envío de WhatsApp

PASO 6: REGISTRAR
- Actualizar $DIR/data/contacted.json añadiendo el contacto:
  {
    \"phone\": \"34XXXXXXXXX\",
    \"name\": \"<nombre o null>\",
    \"url\": \"<url del inmueble>\",
    \"portal\": \"<portal>\",
    \"zone\": \"<zona/dirección>\",
    \"price\": <precio>,
    \"date_contacted\": \"<ISO timestamp>\",
    \"status\": \"sent\" o \"skipped_<razón>\" o \"failed\",
    \"message_preview\": \"<primeros 100 chars del mensaje>\"
  }
- Escribir log en $DIR/data/logs/$DATE.log con timestamp para cada acción
- Al terminar, escribir resumen: X procesados, Y enviados, Z duplicados, W fallidos

REGLAS ESTRICTAS:
- Máximo $SLOTS_LEFT contactos más hoy (ya van $TODAY_COUNT de $MAX_PER_DAY)
- SOLO móviles: números que empiezan por 6 o 7
- SOLO particulares, NUNCA agencias
- Horario válido de envío: 9:00-14:00 y 16:00-20:00 (hora España/Madrid)
- Si estamos fuera de horario, registrar todo pero NO enviar WhatsApp (marcar 'pending_schedule')
- Si detectas captcha o bloqueo en un portal, registra como failed y pasa al siguiente
- Esperar 5-10 segundos entre navegaciones a inmuebles

Directorio de trabajo: $DIR" 2>&1 | tee -a "$LOG"

  echo "" | tee -a "$LOG"
  echo "Run BetterPlace completado — $DATE $(date +%H:%M)" | tee -a "$LOG"

else
  echo "Modo desconocido: $MODE" | tee -a "$LOG"
  echo "Usa: ./run.sh test | dashboard | api | email | server | betterplace" | tee -a "$LOG"
  exit 1
fi
