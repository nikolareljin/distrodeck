#!/usr/bin/env bash
set -euo pipefail

export XDG_STATE_HOME=/workspace/.state
mkdir -p "$XDG_STATE_HOME"

cd /workspace

DC=./distrodeck

log_section() {
  printf "\n== %s ==\n" "$1"
}

log_section "Sanity"
$DC --version >/dev/null

log_section "Clear logs"
$DC clear-logs

log_section "Doctor"
set +e
$DC doctor --verbose
set -e

log_section "Doctor JSON"
set +e
$DC doctor --json > /workspace/.state/doctor.json
doctor_json_rc=$?
set -e

python3 -c "import json; json.load(open('/workspace/.state/doctor.json'))" >/dev/null
doctor_status=$(python3 -c "import json; print(json.load(open('/workspace/.state/doctor.json'))['status'])")
if [[ "$doctor_status" == "blocker" && "$doctor_json_rc" -eq 0 ]]; then
  echo "doctor --json should exit non-zero when status is blocker" >&2
  exit 1
fi
if [[ "$doctor_status" != "blocker" && "$doctor_json_rc" -ne 0 ]]; then
  echo "doctor --json should exit zero for non-blocker status" >&2
  exit 1
fi

log_section "Preflight"
$DC preflight

log_section "Sysinfo"
$DC sysinfo

log_section "Export (CLI)"
$DC export --output /workspace/.state/test-export.txt --include-config \
  --config-dirs /etc:/etc/apt --include-config-files \
  --config-files /etc/hosts

log_section "Import (CLI)"
$DC import --input /workspace/tests/fixtures/import-min.txt --apply --sections apt_manual

log_section "Repo repair"
$DC repo-repair || true

log_section "Logs"
$DC logs --latest --tail 50

log_section "TUI smoke"
/workspace/tests/docker/tui_smoke.exp

log_section "TUI export"
/workspace/tests/docker/tui_export.exp

log_section "Done"
