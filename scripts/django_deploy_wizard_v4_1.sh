#!/usr/bin/env bash
set -euo pipefail

# Django Deploy Wizard v4.1
# - Fixes PostgreSQL password prompts under sudo/non-tty by reading from /dev/tty
# - Handles passwords with "!" (disables history expansion)
# - Safe /srv ownership: keep base dir root-owned, project dir owned by service user
# - Installs psycopg drivers when PostgreSQL chosen
# - Optional Nginx + static/media serving
# Usage:
#   sudo bash ./django_deploy_wizard_v4_1.sh install
#   sudo bash ./django_deploy_wizard_v4_1.sh status
#   sudo bash ./django_deploy_wizard_v4_1.sh remove

ACTION="${1:-install}"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; }
warn() { printf "⚠️  %s\n" "$*"; }
err()  { printf "❌ %s\n" "$*" >&2; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root (use sudo)."
    exit 1
  fi
}

prompt() {
  local msg="$1" default="${2:-}"
  if [[ -n "${default}" ]]; then
    read -r -p "${msg} [${default}]: " ans || true
    echo "${ans:-$default}"
  else
    read -r -p "${msg}: " ans || true
    echo "${ans}"
  fi
}

confirm() {
  local msg="$1" default="${2:-Y}" ans
  if [[ "${default}" == "Y" ]]; then
    read -r -p "${msg} [Y/n]: " ans || true
    [[ -z "${ans}" || "${ans}" =~ ^[Yy]$ ]]
  else
    read -r -p "${msg} [y/N]: " ans || true
    [[ "${ans}" =~ ^[Yy]$ ]]
  fi
}

# Read hidden password from /dev/tty even when script is run with sudo and stdin is not a TTY
read_secret() {
  local prompt_msg="$1"
  local var=""
  # Disable history expansion so "!" doesn't break
  set +H || true
  if [[ -r /dev/tty ]]; then
    IFS= read -r -s -p "${prompt_msg}" var < /dev/tty || true
    printf "\n" > /dev/tty
  else
    IFS= read -r -s -p "${prompt_msg}" var || true
    printf "\n"
  fi
  echo "${var}"
}

read_secret_confirm_loop() {
  local label="$1"
  local p1 p2
  while true; do
    p1="$(read_secret "${label}: ")"
    p2="$(read_secret "Confirm ${label}: ")"
    if [[ -n "${p1}" && "${p1}" == "${p2}" ]]; then
      echo "${p1}"
      return 0
    fi
    err "Passwords do not match / empty. Try again."
  done
}

detect_project_root() {
  local dir="$1"
  if [[ -f "${dir}/manage.py" ]]; then
    echo "${dir}"
    return 0
  fi
  local cand
  cand="$(find "${dir}" -maxdepth 2 -name manage.py -print -quit 2>/dev/null || true)"
  if [[ -n "${cand}" ]]; then
    dirname "${cand}"
    return 0
  fi
  return 1
}

install_pkgs() {
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_pkg() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    ok "$pkg already installed"
  else
    install_pkgs "$pkg"
    ok "$pkg installed"
  fi
}

ensure_cmd() {
  local cmd="$1" pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd already installed"
  else
    ensure_pkg "$pkg"
  fi
}

list_nginx_sites() {
  if command -v nginx >/dev/null 2>&1; then
    echo "Enabled Nginx sites:"
    ls -1 /etc/nginx/sites-enabled 2>/dev/null || true
    echo
    nginx -t >/dev/null 2>&1 && echo "nginx config: OK" || echo "nginx config: FAIL"
    systemctl is-active --quiet nginx && echo "nginx service: active" || echo "nginx service: not active"
  else
    echo "nginx is not installed."
  fi
}

write_gunicorn_service() {
  local svc_name="$1" run_user="$2" project_root="$3" venv_python="$4" bind_ip="$5" bind_port="$6" wsgi_module="$7"
  local unit="/etc/systemd/system/${svc_name}.service"
  cat > "${unit}" <<EOF
[Unit]
Description=${svc_name} (Gunicorn)
After=network.target

[Service]
Type=simple
User=${run_user}
Group=${run_user}
WorkingDirectory=${project_root}
Environment=PYTHONUNBUFFERED=1
ExecStart=${venv_python} -m gunicorn ${wsgi_module} --bind ${bind_ip}:${bind_port} --workers 3 --timeout 120
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  ok "Wrote systemd unit: ${unit}"
  systemctl daemon-reload
  systemctl enable --now "${svc_name}.service"
  ok "Started: ${svc_name}.service"
}

install_flow() {
  bold "------------------------------------------------------------"
  bold "Django Deploy Wizard (v4.1) — Install"
  bold "------------------------------------------------------------"

  local base_dir
  base_dir="$(prompt "Choose a base directory for Django projects" "/srv")"
  if [[ ! -d "${base_dir}" ]]; then
    if confirm "Directory ${base_dir} does not exist. Create it?" "Y"; then
      mkdir -p "${base_dir}"
      ok "Created: ${base_dir}"
    else
      err "Cannot continue without a base directory."
      exit 1
    fi
  fi

  # Keep base dir root-owned 755 (don't chown -R /srv to a user)
  chown root:root "${base_dir}" || true
  chmod 755 "${base_dir}" || true
  ok "Base directory ready: ${base_dir} (owner root:root, mode 755)"

  ensure_cmd git git
  local repo_url
  repo_url="$(prompt "Paste the Git repo URL (https or ssh)" "")"
  [[ -n "${repo_url}" ]] || { err "Repo URL is required."; exit 1; }

  local repo_name
  repo_name="$(basename "${repo_url}")"
  repo_name="${repo_name%.git}"

  local run_user
  run_user="$(prompt "Run Django/Gunicorn as user" "${SUDO_USER:-root}")"
  id "${run_user}" >/dev/null 2>&1 || { err "User does not exist: ${run_user}"; exit 1; }
  ok "Service user: ${run_user}"

  local project_folder
  project_folder="$(prompt "Project folder name under ${base_dir}" "${repo_name}")"
  local project_dir="${base_dir}/${project_folder}"

  if [[ -d "${project_dir}/.git" ]]; then
    ok "Repo already cloned at: ${project_dir}"
    if confirm "Do you want to git pull latest changes?" "Y"; then
      chown -R "${run_user}:${run_user}" "${project_dir}" || true
      sudo -u "${run_user}" git -C "${project_dir}" pull
    fi
  else
    mkdir -p "${project_dir}"
    chown -R "${run_user}:${run_user}" "${project_dir}"
    ok "Cloning into: ${project_dir}"
    sudo -u "${run_user}" git clone "${repo_url}" "${project_dir}"
  fi

  local project_root
  project_root="$(detect_project_root "${project_dir}")" || { err "Could not find manage.py under ${project_dir}"; exit 1; }
  ok "Django project root confirmed: ${project_root}"

  ensure_pkg python3-venv
  ensure_pkg python3-pip

  local venv_dir="${project_root}/.venv"
  if [[ -x "${venv_dir}/bin/python" ]]; then
    ok "Virtualenv exists: ${venv_dir}"
  else
    ok "Creating venv: ${venv_dir}"
    sudo -u "${run_user}" python3 -m venv "${venv_dir}"
    ok "Virtualenv created."
  fi
  local vpy="${venv_dir}/bin/python"
  local vpip="${venv_dir}/bin/pip"

  if [[ -f "${project_root}/requirements.txt" ]]; then
    bold "Installing Python dependencies (requirements.txt)"
    sudo -u "${run_user}" "${vpip}" install --upgrade pip wheel setuptools
    sudo -u "${run_user}" "${vpip}" install -r "${project_root}/requirements.txt"
    ok "Python requirements installed."
  else
    warn "No requirements.txt found. Skipping pip install -r."
  fi

  ensure_cmd ffmpeg ffmpeg
  ok "ffmpeg installed: $(ffmpeg -version | head -n 1)"

  if confirm "Set up PostgreSQL (install/check + create DB/user)?" "Y"; then
    ensure_pkg postgresql
    ensure_pkg postgresql-contrib
    ensure_pkg libpq-dev
    systemctl enable --now postgresql
    ok "PostgreSQL service ready."

    # Drivers for Django/PostgreSQL
    sudo -u "${run_user}" "${vpip}" install "psycopg[binary]" psycopg2-binary >/dev/null
    ok "Installed psycopg drivers (psycopg[binary], psycopg2-binary)"

    local db_name db_user db_pass
    db_name="$(prompt "Database name" "ip_transcoder_v2_db")"
    db_user="$(prompt "Database user" "ip_transcoder_v2_user")"
    db_pass="$(read_secret_confirm_loop "PostgreSQL password")"

    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${db_user}'" | grep -q 1; then
      sudo -u postgres psql -c "ALTER USER ${db_user} WITH PASSWORD '${db_pass}';" >/dev/null
      ok "Password updated for existing role: ${db_user}"
    else
      sudo -u postgres psql -c "CREATE USER ${db_user} WITH PASSWORD '${db_pass}';" >/dev/null
      ok "Role created: ${db_user}"
    fi

    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}'" | grep -q 1; then
      ok "Database exists: ${db_name}"
    else
      sudo -u postgres psql -c "CREATE DATABASE ${db_name} OWNER ${db_user};" >/dev/null
      ok "Database created: ${db_name} (owner=${db_user})"
    fi

    sudo -u postgres psql -c "ALTER ROLE ${db_user} SET client_encoding TO 'utf8';" >/dev/null
    sudo -u postgres psql -c "ALTER ROLE ${db_user} SET default_transaction_isolation TO 'read committed';" >/dev/null
    sudo -u postgres psql -c "ALTER ROLE ${db_user} SET timezone TO 'UTC';" >/dev/null
    ok "Role defaults set (encoding, isolation, timezone=UTC)."

    cat <<EOF

------------------------------------------------------------
DB connection info (copy into settings.py)
------------------------------------------------------------
ENGINE  = django.db.backends.postgresql
NAME    = ${db_name}
USER    = ${db_user}
PASSWORD= ${db_pass}
HOST    = 127.0.0.1
PORT    = 5432
------------------------------------------------------------

EOF
  else
    warn "PostgreSQL setup skipped."
  fi

  local static_url media_url static_root media_root
  static_url="$(prompt "STATIC_URL" "/static/")"
  media_url="$(prompt "MEDIA_URL" "/media/")"
  static_root="$(prompt "STATIC_ROOT (absolute path)" "${project_root}/staticfiles")"
  media_root="$(prompt "MEDIA_ROOT (absolute path)" "${project_root}/media")"

  mkdir -p "${static_root}" "${media_root}"
  chown -R "${run_user}:${run_user}" "${static_root}" "${media_root}"
  chmod 755 "${static_root}" "${media_root}"
  ok "Static/Media directories ready."

  cat <<EOF
Suggested settings (set these in your settings.py):
  STATIC_URL  = '${static_url}'
  STATIC_ROOT = r'${static_root}'
  MEDIA_URL   = '${media_url}'
  MEDIA_ROOT  = r'${media_root}'
EOF

  if confirm "Run collectstatic now? (requires STATIC_ROOT set in settings.py)" "N"; then
    sudo -u "${run_user}" "${vpy}" "${project_root}/manage.py" collectstatic --noinput || {
      warn "collectstatic failed. Ensure STATIC_ROOT is set in settings.py and re-run collectstatic."
    }
  fi

  sudo -u "${run_user}" "${vpip}" install gunicorn >/dev/null
  ok "gunicorn installed in venv."

  local bind_ip bind_port
  bind_ip="$(prompt "Gunicorn bind IP (keep 127.0.0.1 behind nginx)" "127.0.0.1")"
  bind_port="$(prompt "Gunicorn bind port" "8000")"

  local settings_py proj_pkg
  settings_py="$(find "${project_root}" -maxdepth 2 -name settings.py -print -quit 2>/dev/null || true)"
  proj_pkg="iptranscoder"
  if [[ -n "${settings_py}" ]]; then
    proj_pkg="$(basename "$(dirname "${settings_py}")")"
  fi
  local wsgi_module="${proj_pkg}.wsgi:application"

  local svc_name
  svc_name="$(prompt "Systemd service name for gunicorn" "${repo_name}_gunicorn")"
  write_gunicorn_service "${svc_name}" "${run_user}" "${project_root}" "${vpy}" "${bind_ip}" "${bind_port}" "${wsgi_module}"

  if confirm "Install/configure Nginx to reverse-proxy to Gunicorn and serve static/media?" "Y"; then
    ensure_pkg nginx
    local site_name server_name listen_port
    site_name="$(prompt "Nginx site name" "${repo_name}")"
    server_name="$(prompt "Server name (domain or IP)" "_")"
    listen_port="$(prompt "Listen port" "80")"

    local nginx_conf="/etc/nginx/sites-available/${site_name}"
    cat > "${nginx_conf}" <<EOF
server {
    listen ${listen_port};
    server_name ${server_name};

    client_max_body_size 100M;

    location ${static_url} {
        alias ${static_root}/;
        expires 7d;
        add_header Cache-Control "public";
    }

    location ${media_url} {
        alias ${media_root}/;
        expires 1d;
        add_header Cache-Control "public";
    }

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_pass http://${bind_ip}:${bind_port};
    }
}
EOF

    ln -sf "${nginx_conf}" "/etc/nginx/sites-enabled/${site_name}"
    rm -f /etc/nginx/sites-enabled/default || true
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
    ok "Nginx configured and reloaded."
  else
    warn "Nginx skipped. Gunicorn bind determines access."
  fi

  bold "------------------------------------------------------------"
  ok "Install flow complete."
  bold "Next steps:"
  echo "1) Edit settings.py to set DATABASES (if using PG), ALLOWED_HOSTS, STATIC_ROOT/MEDIA_ROOT."
  echo "2) Run migrations:   sudo -u ${run_user} ${vpy} ${project_root}/manage.py migrate"
  echo "3) Run migrations:   sudo -u ${run_user} ${vpy} ${project_root}/manage.py createsuperuser"
  echo "4) Collect static:   sudo -u ${run_user} ${vpy} ${project_root}/manage.py collectstatic --noinput"
  echo "5) Restart services: systemctl restart ${svc_name}.service ; systemctl reload nginx (if used)"
  bold "------------------------------------------------------------"
}

status_flow() {
  bold "------------------------------------------------------------"
  bold "Django Deploy Wizard (v4.1) — Status"
  bold "------------------------------------------------------------"
  list_nginx_sites
  echo
  echo "Systemd services (filtered):"
  systemctl list-units --type=service --all | grep -E "gunicorn|ip_transcoder|transcoder" || true
}

remove_flow() {
  bold "------------------------------------------------------------"
  bold "Django Deploy Wizard (v4.1) — Remove"
  bold "------------------------------------------------------------"
  local svc
  svc="$(prompt "Enter the gunicorn systemd service name to remove (without .service)" "")"
  [[ -n "${svc}" ]] || { err "Service name required."; exit 1; }

  if systemctl list-unit-files | awk '{print $1}' | grep -qx "${svc}.service"; then
    systemctl disable --now "${svc}.service" || true
    rm -f "/etc/systemd/system/${svc}.service"
    systemctl daemon-reload
    ok "Removed service: ${svc}.service"
  else
    warn "Service not found: ${svc}.service"
  fi

  if confirm "Remove an nginx site too?" "N"; then
    local site
    site="$(prompt "Nginx site name (file in /etc/nginx/sites-available)" "")"
    if [[ -n "${site}" ]]; then
      rm -f "/etc/nginx/sites-enabled/${site}" "/etc/nginx/sites-available/${site}"
      nginx -t && systemctl reload nginx || true
      ok "Removed nginx site: ${site}"
    fi
  fi
}

need_root
case "${ACTION}" in
  install) install_flow ;;
  status)  status_flow ;;
  remove)  remove_flow ;;
  *) err "Unknown action: ${ACTION} (use install|status|remove)"; exit 1 ;;
esac
