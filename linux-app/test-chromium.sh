#!/bin/bash
/usr/lib/chromium/chromium \
  --app="file:///home/kiiyuu/Projects/project-web/hermes-coucou/dist/index.html" \
  --window-size="700,450" \
  --window-position="610,0" \
  --ozone-platform-hint=auto \
  --user-data-dir="/tmp/coucou-chrome-profile" &
PID=$!
sleep 4
kill $PID
