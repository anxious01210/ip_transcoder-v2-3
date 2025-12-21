#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# enforcer_service.sh (v4)
# # TODO: chmod +x ~/prjs/ip_transcoder-v2/scripts/enforcer_service.sh
# Fix for your latest error:
#   manage.py transcoder_enforcer: error: unrecognized arguments: --log-level=INFO
#
# => We DO NOT pass any extra args by default.
#    If you want args, pass: --extra-args "..."
#
# Project-specific defaults (from your tree):
#   - settings: iptranscoder.settings
#   - command : transcoder_enforcer
#
# Features:
#   - install : create/update unit file, daemon-reload, enable, start, verify
#   - status  : show service status + tail logs
#   - remove  : stop/disable and delete unit file, daemon-reload
# -----------------------------------------------------------------------------

red(){ printf "\033[31m%s\033[0m\n" "$*"; }
green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    red "This script must be run with sudo/root."
    exit 1
  fi
}

detect_project_root() {
  local d="${PWD}"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/manage.py" ]]; then
      echo "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

detect_settings_from_managepy() {
  local manage_py="$1"
  if [[ ! -f "$manage_py" ]]; then
    return 1
  fi
  local found
  found="$(python3 - <<PY 2>/dev/null || true
import re, pathlib
p = pathlib.Path(r'''$manage_py''')
s = p.read_text(encoding='utf-8', errors='ignore')
m = re.search(r"os\.environ\.setdefault\(\s*['\"]DJANGO_SETTINGS_MODULE['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*\)", s)
print(m.group(1) if m else "")
PY
)"
  if [[ -n "${found}" ]]; then
    echo "${found}"
    return 0
  fi
  return 1
}

usage() {
  cat <<EOF
Usage:
  sudo bash $0 <install|status|remove> [options]

Options:
  --service NAME        Service name (default: ip_transcoder_enforcer)
  --user USER           Run as this user (default: SUDO_USER)
  --project-root PATH   Project root containing manage.py (default: auto-detect)
  --python PATH         Python executable (default: <project_root>/.venv/bin/python)
  --settings MODULE     DJANGO_SETTINGS_MODULE (default: auto from manage.py; fallback iptranscoder.settings)
  --command CMD         Django management command (default: transcoder_enforcer)
  --extra-args "..."    Extra args appended after command (default: empty)

Examples:
  sudo bash $0 install
  sudo bash $0 install --extra-args "--some-flag 123"
  sudo bash $0 status
  sudo bash $0 remove
EOF
}

service_path_for() {
  local svc="$1"
  echo "/etc/systemd/system/${svc}.service"
}

service_exists() {
  local svc="$1"
  local p
  p="$(service_path_for "$svc")"
  [[ -f "$p" ]] || systemctl list-unit-files | awk '{print $1}' | grep -qx "${svc}.service"
}

write_service_file() {
  local svc="$1"
  local run_user="$2"
  local project_root="$3"
  local py="$4"
  local settings="$5"
  local cmd="$6"
  local extra_args="$7"

  local manage_py="${project_root}/manage.py"
  if [[ ! -f "$manage_py" ]]; then
    red "manage.py not found: ${manage_py}"
    exit 1
  fi
  if [[ ! -x "$py" ]]; then
    red "Python executable not found or not executable: ${py}"
    exit 1
  fi

  local unit_path
  unit_path="$(service_path_for "$svc")"
  yellow "Writing unit: ${unit_path}"

  local env_prefix="/usr/bin/env PYTHONUNBUFFERED=1"
  if [[ -n "${settings}" ]]; then
    env_prefix="/usr/bin/env DJANGO_SETTINGS_MODULE=${settings} PYTHONUNBUFFERED=1"
  fi

  # If extra_args empty, avoid trailing double-spaces
  local exec_line="${env_prefix} ${py} ${manage_py} ${cmd}"
  if [[ -n "${extra_args}" ]]; then
    exec_line="${exec_line} ${extra_args}"
  fi

  cat > "${unit_path}" <<EOF
[Unit]
Description=IP Transcoder Enforcer (Django management command)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
WorkingDirectory=${project_root}

Environment=PYTHONPATH=${project_root}
ExecStart=${exec_line}

Restart=always
RestartSec=3
TimeoutStopSec=15

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "${unit_path}"
}

do_install() {
  local svc="$1"
  local run_user="$2"
  local project_root="$3"
  local py="$4"
  local settings="$5"
  local cmd="$6"
  local extra_args="$7"

  if service_exists "$svc"; then
    yellow "Service already exists: ${svc}.service (unit will be overwritten)"
  else
    yellow "Service does not exist yet: ${svc}.service"
  fi

  write_service_file "$svc" "$run_user" "$project_root" "$py" "$settings" "$cmd" "$extra_args"

  yellow "Validating unit file..."
  systemd-analyze verify "$(service_path_for "$svc")" || true

  yellow "Reloading systemd..."
  systemctl daemon-reload

  yellow "Enabling service..."
  systemctl enable "${svc}.service" >/dev/null

  yellow "Starting service..."
  systemctl restart "${svc}.service"

  sleep 1

  if systemctl is-active --quiet "${svc}.service"; then
    green "✅ ACTIVE: ${svc}.service"
  else
    red "❌ NOT ACTIVE: ${svc}.service"
    systemctl status "${svc}.service" -l --no-pager || true
    red "Last 120 log lines:"
    journalctl -u "${svc}.service" -n 120 --no-pager || true
    exit 1
  fi

  yellow "Status summary:"
  systemctl status "${svc}.service" -l --no-pager | sed -n '1,25p' || true
  yellow "Recent logs (last 80 lines):"
  journalctl -u "${svc}.service" -n 80 --no-pager || true
}

do_status() {
  local svc="$1"
  if ! service_exists "$svc"; then
    red "Service not found: ${svc}.service"
    exit 2
  fi
  systemctl status "${svc}.service" -l --no-pager || true
  yellow "Recent logs (last 120 lines):"
  journalctl -u "${svc}.service" -n 120 --no-pager || true
}

do_remove() {
  local svc="$1"
  local unit_path
  unit_path="$(service_path_for "$svc")"

  if ! service_exists "$svc"; then
    yellow "Service not found: ${svc}.service (nothing to remove)"
    return 0
  fi

  yellow "Stopping service..."
  systemctl stop "${svc}.service" >/dev/null 2>&1 || true

  yellow "Disabling service..."
  systemctl disable "${svc}.service" >/dev/null 2>&1 || true

  rm -f "/etc/systemd/system/multi-user.target.wants/${svc}.service" || true

  if [[ -f "${unit_path}" ]]; then
    yellow "Deleting unit file: ${unit_path}"
    rm -f "${unit_path}"
  else
    yellow "Unit file not in /etc/systemd/system (may be packaged). Leaving as-is."
  fi

  yellow "Reloading systemd..."
  systemctl daemon-reload
  systemctl reset-failed "${svc}.service" >/dev/null 2>&1 || true

  green "✅ Removed/disabled: ${svc}.service"
}

ACTION="${1:-}"
shift || true

SERVICE="ip_transcoder_enforcer"
RUN_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER:-root}")}"
PROJECT_ROOT=""
PYTHON_PATH=""
SETTINGS=""  # auto from manage.py; fallback iptranscoder.settings
DJANGO_CMD="transcoder_enforcer"
EXTRA_ARGS=""  # IMPORTANT: default empty

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE="${2:-}"; shift 2;;
    --user) RUN_USER="${2:-}"; shift 2;;
    --project-root) PROJECT_ROOT="${2:-}"; shift 2;;
    --python) PYTHON_PATH="${2:-}"; shift 2;;
    --settings) SETTINGS="${2:-}"; shift 2;;
    --command) DJANGO_CMD="${2:-}"; shift 2;;
    --extra-args) EXTRA_ARGS="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) red "Unknown argument: $1"; usage; exit 2;;
  esac
done

main() {
  require_root

  if [[ -z "${ACTION}" ]]; then
    usage
    exit 2
  fi

  if [[ -z "${PROJECT_ROOT}" ]]; then
    if ! PROJECT_ROOT="$(detect_project_root)"; then
      red "Could not auto-detect project root (manage.py not found by walking up from: ${PWD})."
      exit 1
    fi
  fi

  if [[ -z "${PYTHON_PATH}" ]]; then
    PYTHON_PATH="${PROJECT_ROOT}/.venv/bin/python"
  fi

  if [[ -z "${SETTINGS}" ]]; then
    local_manage_py="${PROJECT_ROOT}/manage.py"
    SETTINGS_DETECTED="$(detect_settings_from_managepy "${local_manage_py}")" || true
    if [[ -n "${SETTINGS_DETECTED}" ]]; then
      SETTINGS="${SETTINGS_DETECTED}"
    else
      SETTINGS="iptranscoder.settings"
    fi
  fi

  case "${ACTION}" in
    install) do_install "${SERVICE}" "${RUN_USER}" "${PROJECT_ROOT}" "${PYTHON_PATH}" "${SETTINGS}" "${DJANGO_CMD}" "${EXTRA_ARGS}" ;;
    status)  do_status  "${SERVICE}" ;;
    remove)  do_remove  "${SERVICE}" ;;
    *) red "Unknown action: ${ACTION}"; usage; exit 2;;
  esac
}

main
