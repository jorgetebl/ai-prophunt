#!/bin/bash
# Fix: start-server.sh finds node at runtime
INSTALL_DIR="$HOME/ai-prophunt"
cat > "$INSTALL_DIR/start-server.sh" <<'INNEREOF'
#!/bin/bash
cd "$HOME/ai-prophunt" || exit 1
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
exec node "$HOME/ai-prophunt/server.bundle.cjs"
INNEREOF
chmod +x "$INSTALL_DIR/start-server.sh"
echo "start-server.sh arreglado"
echo "Ejecuta: prophunt start"
