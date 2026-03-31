---
name: commit
description: Commit, push to GitHub (cuenta jorgetebl) y aplicar migraciones pendientes de Supabase. Usar cuando el usuario diga /commit o pida hacer commit/push/deploy.
allowed-tools: Bash(git:*), Bash(gh:*), Bash(curl:*)
---

# /commit — Commit + Push + Migraciones Supabase

Cuando el usuario invoque este skill, sigue estos pasos EN ORDEN:

## 1. Preparar git

```bash
gh auth switch --user jorgetebl
```

## 2. Analizar cambios

- Ejecuta `git status` y `git diff --staged` y `git diff` para ver qué hay.
- Ejecuta `git log --oneline -5` para ver el estilo de commits recientes.
- Si no hay cambios, informa y para.

## 3. Hacer commit

- Añade los archivos relevantes (NO uses `git add .` ni `git add -A` — añade archivos específicos).
- NO incluyas archivos sensibles (.env, credenciales, tokens).
- NO incluyas node_modules, .temp, ni archivos de build.
- Genera un mensaje de commit conciso en inglés, estilo imperativo, enfocado en el "por qué".
- Termina con:
  ```
  Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
  ```
- Usa HEREDOC para el mensaje:
  ```bash
  git commit -m "$(cat <<'EOF'
  Mensaje aquí

  Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
  EOF
  )"
  ```

## 4. Push

```bash
git push origin main
```

Si falla el push (ej: rejected), NO hagas force push. Informa al usuario.

## 5. Migraciones Supabase

Después del push, comprueba si hay migraciones SQL pendientes en `supabase/`.

Para saber qué ya está aplicado, consulta las tablas existentes:

```bash
TOKEN=$SUPABASE_ACCESS_TOKEN
curl -s -X POST "https://api.supabase.com/v1/projects/uolymolzgesvxucmbcgw/database/query" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "SELECT tablename FROM pg_tables WHERE schemaname = '\''public'\''"}'
```

Archivos de migración:
- `supabase/schema.sql` — tablas: contacts, logs, configs, setup_tokens + funciones + RLS + índices
- `supabase/stripe-schema.sql` — tabla: subscriptions + has_active_subscription() + índices

Si una tabla ya existe, NO re-ejecutes ese archivo. Solo aplica lo que falte.

Para aplicar una migración:

```bash
TOKEN=$SUPABASE_ACCESS_TOKEN
curl -s -X POST "https://api.supabase.com/v1/projects/uolymolzgesvxucmbcgw/database/query" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "<contenido del .sql escapado>"}'
```

Informa qué migraciones se aplicaron y cuáles ya estaban.

## 6. Resumen

Al final, muestra un resumen:
- Archivos commiteados
- Hash del commit
- Estado del push
- Migraciones aplicadas (o "todas al día")
