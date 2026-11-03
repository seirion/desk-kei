#!/bin/bash
# 번들을 만들어 /Applications 에 설치한다.  사용법: Scripts/deploy-app.sh
# 실행 중이면 종료한 뒤 교체하고, 실행 중이었다면 다시 연다.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="/Applications/DeskKei.app"
BUNDLE_ID="com.deskkei.app"

Scripts/build-app.sh

was_running=false
if pgrep -x DeskKei >/dev/null; then
    was_running=true
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
        pgrep -x DeskKei >/dev/null || break
        sleep 0.1
    done
    if pgrep -x DeskKei >/dev/null; then
        echo "Desk Kei 가 종료되지 않았습니다. 직접 종료한 뒤 다시 실행하세요." >&2
        exit 1
    fi
fi

rm -rf "$DEST"
cp -R build/DeskKei.app "$DEST"
echo "Installed $DEST"

if $was_running; then
    open "$DEST"
fi
