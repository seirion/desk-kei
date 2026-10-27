#!/bin/bash
# Release 빌드 후 DeskKei.app 번들을 만든다.  사용법: Scripts/build-app.sh [출력 디렉터리(기본: build)]
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/DeskKei.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/DeskKei"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/DeskKei"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Desk Kei</string>
    <key>CFBundleDisplayName</key><string>Desk Kei</string>
    <key>CFBundleIdentifier</key><string>com.deskkei.app</string>
    <key>CFBundleExecutable</key><string>DeskKei</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- 실시간 시세 서버가 평문 ws:// (포트 21000) 만 제공한다 -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSExceptionDomains</key>
        <dict>
            <key>ops.koreainvestment.com</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
