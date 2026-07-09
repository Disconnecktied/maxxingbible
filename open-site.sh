#!/usr/bin/env bash
# One-command local launcher for The RetardMaxxing Bible.
# A local server is required so magic-link sign-in and Supabase calls work
# (they don't work from a file:// path).
set -e
PORT="${1:-8917}"
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
URL="http://localhost:${PORT}"
echo "🔥 RetardMaxxing Bible → ${URL}"
echo "   (Ctrl+C to stop)"
# Try to open a browser, ignore if headless.
( command -v xdg-open >/dev/null && xdg-open "$URL" ) 2>/dev/null &
( command -v open >/dev/null && open "$URL" ) 2>/dev/null &
exec python3 -m http.server "$PORT"
