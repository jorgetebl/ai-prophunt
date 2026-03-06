# AI PropHunt

Captacion inmobiliaria automatizada para Juanan Gomis — REMAX Experience, Palma de Mallorca.

Detecta inmuebles de particulares, extrae el telefono del vendedor, y envia un WhatsApp personalizado con datos de la ficha del inmueble.

## Requisitos

- macOS
- Chrome con la extension de Claude Code instalada
- Cuenta de Anthropic con Claude Code CLI

## Instalacion

```bash
git clone <repo-url> ai-prophunt
cd ai-prophunt
chmod +x setup.sh run.sh scripts/*.sh
./setup.sh
```

El script `setup.sh` instala todo lo necesario:
- **wacli** (envio de WhatsApp desde terminal)
- **jq** (procesamiento de JSON)
- Verifica que Claude Code y Chrome estan instalados
- Crea los directorios de datos
- Te guia para vincular WhatsApp (escanear QR)
- Te recuerda loguearte en Idealista/Fotocasa/Pisos.com en Chrome

## Primera prueba

Antes de activar el modo automatico, haz una prueba completa para verificar que todo funciona:

```bash
./run.sh test
```

Esto hace un ciclo completo de principio a fin:

1. Abre Gmail en Chrome y busca un email de Idealista
2. Abre el link del inmueble en Chrome
3. Lee la ficha completa (zona, precio, m2, habitaciones, caracteristicas)
4. Hace click en "Ver telefono" para extraer el numero
5. Construye un WhatsApp personalizado con los datos reales de la ficha
6. Envia el WhatsApp al numero de test (+34 629 659 757), NO al vendedor
7. Registra todo en `data/contacted.json` y `data/logs/`

Por defecto envia al +34 629 659 757. Para usar otro numero de prueba:

```bash
./run.sh test +34612345678
```

**Antes de lanzar la prueba, asegurate de:**
- Chrome esta abierto con Gmail logueado
- Hay al menos un email de Idealista en la bandeja
- wacli esta autenticado (`wacli doctor`)

## Dashboard

Panel web para ver el estado sin usar terminal:

```bash
./run.sh dashboard
```

Se abre automaticamente en http://localhost:3456. Muestra:
- Contactos de hoy / en cola / enviados / fallidos
- Tabla con historial de contactos (filtrable por hoy/semana/todos)
- Log del dia en tiempo real
- Estado del sistema (wacli, Chrome, disco, cron)
- Boton para lanzar ejecucion de BetterPlace

## Modos de ejecucion

| Comando | Descripcion |
|---|---|
| `./run.sh test [+34XXX]` | Prueba completa con telefono de test |
| `./run.sh dashboard` | Dashboard web en localhost:3456 |
| `./run.sh betterplace` | Automatico: Gmail → Chrome → WhatsApp |
| `./run.sh api [--dry-run]` | Buscar via API Idealista |
| `./run.sh email <archivo>` | Procesar email de BetterPlace desde archivo |
| `./run.sh server [--dry-run]` | Servidor HTTP puente (Chrome ext ↔ wacli) |

## Ejecucion automatica diaria

Una vez verificado con `./run.sh test`:

```bash
./scripts/install_cron.sh
```

Configura:
- El Mac se despierta a las 07:58
- A las 08:00 ejecuta `./run.sh betterplace`
- Lee Gmail, procesa inmuebles de BetterPlace, envia WhatsApps
- Maximo 15 contactos/dia, 2 min entre cada uno
- Solo en horario laboral (9-14h y 16-20h)

## Personalizacion del mensaje

La plantilla esta en `templates/whatsapp.txt`. Campos disponibles:

| Campo | Ejemplo | Fuente |
|---|---|---|
| `{{nombre}}` | Maria Lopez | Nombre del anunciante (si aparece) |
| `{{tipo}}` | piso, atico, casa | Tipo de inmueble de la ficha |
| `{{zona}}` | Calle Rossello 59, Palma | Direccion del anuncio |
| `{{portal}}` | idealista | Portal de origen |
| `{{precio}}` | 350.000 € | Precio del anuncio |
| `{{detalle}}` | Los 85 m2 con terraza tienen buena pinta | Frase generada por IA leyendo la ficha |

Si no hay nombre, el saludo cambia automaticamente de "Hola Maria, soy..." a "Hola, soy...".
Si no hay precio, se omite "por X €" del mensaje.
El `{{detalle}}` se genera automaticamente con algo concreto y positivo de la ficha.

## Estructura del proyecto

```
ai-prophunt/
├── run.sh                  Punto de entrada principal
├── setup.sh                Instalacion guiada
├── config.json             Configuracion (limites, horarios, filtros)
├── CLAUDE.md               Instrucciones para Claude Code
├── templates/
│   └── whatsapp.txt        Plantilla del mensaje WhatsApp
├── src/
│   ├── server.js           Servidor HTTP + API del dashboard
│   ├── queue.js            Cola de envio con rate limiting
│   ├── message.js          Construccion de mensajes personalizados
│   ├── filter.js           Filtro de duplicados
│   ├── phone.js            Normalizacion de telefonos
│   └── logger.js           Logging
├── public/
│   └── index.html          Dashboard web
├── data/
│   ├── contacted.json      Registro de contactos (anti-duplicados)
│   └── logs/               Logs diarios
└── scripts/
    ├── healthcheck.sh      Verificacion del sistema
    └── install_cron.sh     Configurar ejecucion automatica
```

## Actualizaciones remotas

El software se actualiza automaticamente. Cada vez que se ejecuta `run.sh` (manual o via cron), comprueba si hay una version nueva en el repo y la descarga antes de ejecutar.

Funcionamiento:
- Hace `git fetch` + `git merge --ff-only` (solo fast-forward, nunca conflictos)
- Si no hay internet, continua con la version actual sin error
- Timeout de 10 segundos para no bloquear
- `config.json`, `data/contacted.json` y `data/logs/` nunca se tocan (estan en .gitignore)
- Si `run.sh` cambia con la actualizacion, se re-ejecuta automaticamente con la nueva version

Para desactivar:

```json
// En config.json
"auto_update": false
```

Flujo de desarrollo:
1. Tu (desarrollador) haces cambios en tu maquina
2. `git push` al repo privado
3. La proxima vez que el equipo de Juanan ejecute `run.sh` (o el cron lo lance), se actualiza solo

## Seguridad

- Maximo 15 contactos por dia (configurable en config.json)
- Minimo 2 minutos entre cada WhatsApp
- Solo contacta moviles (prefijo 6 o 7)
- Solo contacta particulares, nunca agencias
- No contacta numeros ya registrados en contacted.json
- Horario: 9:00-14:00 y 16:00-20:00 (hora Madrid)
- Si detecta captcha o bloqueo, para y pasa al siguiente

## Comandos utiles

```bash
# Ver contactos de hoy
cat data/logs/$(date +%Y-%m-%d).log

# Total de contactos registrados
jq '.contacts | length' data/contacted.json

# Estado de WhatsApp
wacli doctor

# Health check completo
./scripts/healthcheck.sh

# Desactivar ejecucion automatica
launchctl unload ~/Library/LaunchAgents/com.prophunt.daily.plist
```
