#!/bin/bash
# Auto-update desde el repo remoto.
# Se ejecuta antes de cada run. Si falla (sin internet, etc.), continua sin actualizar.
#
# Protecciones:
# - No toca data/, logs, ni config.json (estan en .gitignore)
# - Si run.sh cambia, re-ejecuta el script actualizado
# - Timeout de 10s para no bloquear si no hay red
# - Solo hace fast-forward (nunca merge conflicts)

set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

LOG="data/logs/$(date +%Y-%m-%d).log"

# Skip si no es un repo git
if [[ ! -d .git ]]; then
  exit 0
fi

# Skip si no hay remote configurado
if ! git remote get-url origin >/dev/null 2>&1; then
  exit 0
fi

# Skip si el usuario ha desactivado auto-update
if [[ "$(jq -r '.auto_update // true' config.json 2>/dev/null)" == "false" ]]; then
  exit 0
fi

# Guardar hash actual de run.sh para detectar si cambia
RUNSH_HASH_BEFORE=""
if [[ -f run.sh ]]; then
  RUNSH_HASH_BEFORE=$(md5 -q run.sh 2>/dev/null || md5sum run.sh 2>/dev/null | cut -d' ' -f1)
fi

# Fetch con timeout de 10s
echo "$(date +%H:%M) - Buscando actualizaciones..." >> "$LOG" 2>/dev/null || true

if ! timeout 10 git fetch origin main 2>/dev/null; then
  echo "$(date +%H:%M) - Sin conexion o timeout, continuando sin actualizar" >> "$LOG" 2>/dev/null || true
  exit 0
fi

# Ver si hay cambios
LOCAL=$(git rev-parse HEAD 2>/dev/null)
REMOTE=$(git rev-parse origin/main 2>/dev/null)

if [[ "$LOCAL" == "$REMOTE" ]]; then
  echo "$(date +%H:%M) - Ya esta actualizado (${LOCAL:0:7})" >> "$LOG" 2>/dev/null || true
  exit 0
fi

# Verificar que podemos hacer fast-forward (no hay cambios locales en tracked files)
if ! git diff --quiet HEAD 2>/dev/null; then
  echo "$(date +%H:%M) - Hay cambios locales, no se actualiza automaticamente" >> "$LOG" 2>/dev/null || true
  exit 0
fi

# Fast-forward merge
if git merge --ff-only origin/main 2>/dev/null; then
  NEW_HASH=$(git rev-parse --short HEAD)
  echo "$(date +%H:%M) - Actualizado a $NEW_HASH" >> "$LOG" 2>/dev/null || true

  # Si run.sh cambio, avisar al caller (exit code 42)
  RUNSH_HASH_AFTER=""
  if [[ -f run.sh ]]; then
    RUNSH_HASH_AFTER=$(md5 -q run.sh 2>/dev/null || md5sum run.sh 2>/dev/null | cut -d' ' -f1)
  fi

  if [[ "$RUNSH_HASH_BEFORE" != "$RUNSH_HASH_AFTER" ]]; then
    echo "$(date +%H:%M) - run.sh actualizado, re-ejecutando..." >> "$LOG" 2>/dev/null || true
    exit 42
  fi
else
  echo "$(date +%H:%M) - No se pudo actualizar (conflicto), continuando con version actual" >> "$LOG" 2>/dev/null || true
fi

exit 0
