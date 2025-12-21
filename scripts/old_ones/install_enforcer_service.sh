#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------
# IP Transcoder Enforcer Installer (Ubuntu)
# -----------------------------------------
# - Installs ffmpeg if missing
# - Creates systemd service for Django enforcer
# - (Optional) Adds logrotate for media/ffmpeg_logs
# chmod +x install_enforcer_service.sh
# sudo bash ./install_enforcer_service.sh
# sudo systemctl status ip_transcoder_enforcer.service
# sudo journalctl -u ip_transcoder_enforcer.service -f
# -----------------------------------------

green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
red(){ echo -e "\033[31m$*\033[0m"; }
die(){ red "ERROR: $*"; exit 1; }

need_root(){
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash $0"
  fi
}

ask(){
  local prompt="$1"
  local default="${2:-}"
  local ans=""
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " ans
    echo "${ans:-$default}"
  else
    read -r -p "$prompt: " ans
    echo "$ans"
  fi
}

yesno(){
  local prompt="$1"
  local default="${2:-y}"
  local ans=""
  local suffix="[y/N]"
  [[ "$default" == "y" ]] && suffix="[Y/n]"
  read -r -p "$prompt $suffix: " ans
  ans="${ans,,}"
  if [[ -z "$ans" ]]; then ans="$default"; fi
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

detect_project_root(){
  # Assume script is placed in project root
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "$here"
}

install_ffmpeg_if_needed(){
  if command -v ffmpeg >/dev/null 2>&1; then
    green "ffmpeg already installed: $(ffmpeg -version | head -n 1)"
    return
  fi

  yellow "ffmpeg not found. Installing..."
  apt-get update -y
  apt-get install -y ffmpeg
  green "ffmpeg installed: $(ffmpeg -version | head -n 1)"
}

write_systemd_service(){
  local service_name="$1"
  local user="$2"
  local workdir="$3"
  local venv_python="$4"
  local manage_py="$5"
  local env_file="$6"

  local unit_path="/etc/systemd/system/${service_name}.service"

  green "Creating systemd service: ${unit_path}"

  cat > "$unit_path" <<EOF
[Unit]
Description=IP Transcoder Enforcer
After=network.target

[Service]
Type=simple
User=${user}
WorkingDirectory=${workdir}
EnvironmentFile=${env_file}
ExecStart=${venv_python} ${manage_py} transcoder_enforcer
Restart=always
RestartSec=3
KillSignal=SIGINT
TimeoutStopSec=15

# Helpful defaults
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

  green "Service file written."
}

write_env_file(){
  local service_name="$1"
  local env_path="/etc/default/${service_name}"
  local django_settings_module="$2"

  green "Creating env file: ${env_path}"

  cat > "$env_path" <<EOF
# Environment for ${service_name}
DJANGO_SETTINGS_MODULE=${django_settings_module}
# Add extra env vars here if you need them:
# SECRET_KEY=...
# DATABASE_URL=...
EOF

  chmod 0644 "$env_path"
  green "Env file written."
}

write_logrotate(){
  local service_name="$1"
  local media_root="$2"
  local logrotate_path="/etc/logrotate.d/${service_name}"

  green "Creating logrotate: ${logrotate_path}"

  cat > "$logrotate_path" <<EOF
${media_root%/}/ffmpeg_logs/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF

  chmod 0644 "$logrotate_path"
  green "Logrotate written."
}

systemd_reload_enable_start(){
  local service_name="$1"

  green "Reloading systemd..."
  systemctl daemon-reload

  green "Enabling service..."
  systemctl enable "${service_name}.service"

  green "Starting service..."
  systemctl restart "${service_name}.service"

  green "Service status:"
  systemctl --no-pager -l status "${service_name}.service" || true

  echo
  green "Useful commands:"
  echo "  sudo systemctl status ${service_name}.service"
  echo "  sudo journalctl -u ${service_name}.service -f"
}

main(){
  need_root

  local project_root
  project_root="$(detect_project_root)"

  green "Project root detected: ${project_root}"

  # Basic prompts
  local service_name
  service_name="$(ask "Service name" "ip_transcoder_enforcer")"

  local run_user
  run_user="$(ask "Run service as user" "rio")"

  local django_settings
  django_settings="$(ask "DJANGO_SETTINGS_MODULE" "ip_transcoder.settings")"

  local venv_python_default="${project_root}/.venv/bin/python"
  local venv_python
  venv_python="$(ask "Path to venv python" "$venv_python_default")"
  [[ -x "$venv_python" ]] || die "venv python not found or not executable: $venv_python"

  local manage_py="${project_root}/manage.py"
  [[ -f "$manage_py" ]] || die "manage.py not found at: $manage_py"

  # Ensure media directories exist
  local media_root="${project_root}/media"
  mkdir -p "${media_root}/ffmpeg_logs" "${media_root}/tmp_playlists"
  chown -R "${run_user}:${run_user}" "${media_root}" || true

  # Install ffmpeg if missing
  install_ffmpeg_if_needed

  # Env file
  write_env_file "$service_name" "$django_settings"

  # systemd service
  write_systemd_service "$service_name" "$project_root" "$project_root" "$venv_python" "$manage_py" "/etc/default/${service_name}"

  # logrotate optional
  if yesno "Install logrotate for media/ffmpeg_logs (recommended)?" "y"; then
    write_logrotate "$service_name" "$media_root"
  else
    yellow "Skipping logrotate."
  fi

  # Reload + enable + start
  systemd_reload_enable_start "$service_name"

  green "Done."
}

main "$@"
