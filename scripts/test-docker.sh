#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p .state

compose=(docker compose -f docker-compose.yml)

"${compose[@]}" build
"${compose[@]}" up -d

# Give systemd a moment to initialize
sleep 3

"${compose[@]}" exec -T distrodeck-test bash -lc "systemctl is-system-running --wait || true"
"${compose[@]}" exec -T distrodeck-test bash -lc "systemctl start dbus || true"
"${compose[@]}" exec -T distrodeck-test bash -lc "systemctl start snapd.socket snapd.service || true"

"${compose[@]}" exec -T distrodeck-test bash -lc "/workspace/tests/docker/run-tests.sh"

"${compose[@]}" down
