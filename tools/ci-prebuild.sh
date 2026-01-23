#!/usr/bin/env bash
set -euo pipefail

if [[ -d ./vendor/script-helpers/scripts ]]; then
  chmod +x ./vendor/script-helpers/scripts/*.sh || true
fi

chmod +x ./tools/gen-man.sh || true

./tools/gen-man.sh
