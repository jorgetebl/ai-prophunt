#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$DIR/.." && pwd)"

APP_NAME="PropHunt"
APP_DIR="$DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

echo "Compilando $APP_NAME..."

# Compile Swift
swiftc -o "$DIR/prophunt-agent" "$DIR/PropHuntAgent.swift" \
  -framework Cocoa \
  -O

echo "Creando $APP_NAME.app..."

# Create .app bundle structure
rm -rf "$APP_DIR"
mkdir -p "$MACOS"

# Move binary
mv "$DIR/prophunt-agent" "$MACOS/$APP_NAME"

# Create Info.plist
cat > "$CONTENTS/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PropHunt</string>
    <key>CFBundleDisplayName</key>
    <string>AI PropHunt</string>
    <key>CFBundleIdentifier</key>
    <string>com.prophunt.agent</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>PropHunt</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo ""
echo "✅ $APP_DIR creado"
echo ""
echo "Para probarlo:"
echo "  open $APP_DIR"
echo ""
echo "Para instalar:"
echo "  cp -r $APP_DIR /Applications/"
echo ""
echo "Para auto-arrancar con el Mac:"
echo "  osascript -e 'tell application \"System Events\" to make login item at end with properties {path:\"$APP_DIR\", hidden:true}'"
