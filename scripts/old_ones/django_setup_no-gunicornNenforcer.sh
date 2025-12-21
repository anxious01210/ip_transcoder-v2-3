#!/usr/bin/env bash
# chmod +x scripts/django_full_stack_setup.sh
# sudo bash scripts/django_full_stack_setup.sh
set -euo pipefail

green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
red(){ echo -e "\033[31m$*\033[0m"; }
die(){ red "ERROR: $*"; exit 1; }

need_root(){
  [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"
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
  [[ -z "$ans" ]] && ans="$default"
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

randpw(){
  python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(48)))
PY
}

apt_install(){
  local pkgs=("$@")
  yellow "Installing packages: ${pkgs[*]}"
  apt-get update -y
  apt-get install -y "${pkgs[@]}"
}

ensure_user_group(){
  local user="$1"
  local group="$2"

  if ! getent group "$group" >/dev/null; then
    green "Creating group: $group"
    groupadd --system "$group"
  else
    green "Group exists: $group"
  fi

  if ! id -u "$user" >/dev/null 2>&1; then
    green "Creating user: $user"
    useradd --system --gid "$group" --create-home --home-dir "/home/$user" --shell /bin/bash "$user"
  else
    green "User exists: $user"
  fi
}

setup_dirs(){
  local app_name="$1"
  local app_user="$2"
  local app_group="$3"

  local base="/srv/${app_name}"
  mkdir -p "$base"/{app,venv,logs,run}
  mkdir -p "$base/app"/{media,static}
  chown -R "$app_user:$app_group" "$base"
  chmod 755 "$base"

  green "Folder layout:"
  echo "  /srv/${app_name}/app   (Django code, manage.py here)"
  echo "  /srv/${app_name}/venv  (venv or pyenv-venv target)"
  echo "  /srv/${app_name}/logs  (gunicorn logs)"
  echo "  /srv/${app_name}/run   (runtime files if needed)"
}

run_as_user(){
  local user="$1"; shift
  sudo -u "$user" -H bash -lc "$*"
}

# -----------------------------
# pyenv helpers
# -----------------------------
ensure_pyenv_deps(){
  apt_install \
    make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
    libsqlite3-dev wget curl llvm libncursesw5-dev xz-utils tk-dev \
    libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev git ca-certificates
}

pyenv_init_cmd='export PYENV_ROOT="$HOME/.pyenv"; export PATH="$PYENV_ROOT/bin:$PATH"; eval "$(pyenv init -)"'

pyenv_exists_for_user(){
  local user="$1"
  run_as_user "$user" "$pyenv_init_cmd; command -v pyenv >/dev/null 2>&1" && return 0 || return 1
}

install_pyenv_for_user(){
  local user="$1"
  green "Installing pyenv for user: $user"
  ensure_pyenv_deps

  run_as_user "$user" '
    set -e
    if [[ ! -d "$HOME/.pyenv" ]]; then
      git clone https://github.com/pyenv/pyenv.git "$HOME/.pyenv"
    fi
    grep -q "PYENV_ROOT" "$HOME/.bashrc" 2>/dev/null || cat >> "$HOME/.bashrc" <<'"'"'RC'"'"'

# --- pyenv ---
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
# --- /pyenv ---
RC
  '
  green "pyenv installed. It will be available in new shells for $user."
}

show_pyenv_versions(){
  local user="$1"
  echo
  green "pyenv versions for $user:"
  run_as_user "$user" "$pyenv_init_cmd; pyenv versions --bare || true"
}

install_python_with_pyenv(){
  local user="$1"
  local ver="$2"
  green "Installing Python ${ver} via pyenv for user $user (this can take a few minutes)..."
  run_as_user "$user" "$pyenv_init_cmd; pyenv install -s ${ver}"
  green "Installed: ${ver}"
}

create_pyenv_venv(){
  local user="$1"
  local python_ver="$2"
  local venv_name="$3"
  green "Creating pyenv virtualenv: ${venv_name} (Python ${python_ver})"
  # Ensure pyenv-virtualenv plugin
  run_as_user "$user" '
    set -e
    export PYENV_ROOT="$HOME/.pyenv"
    mkdir -p "$PYENV_ROOT/plugins"
    if [[ ! -d "$PYENV_ROOT/plugins/pyenv-virtualenv" ]]; then
      git clone https://github.com/pyenv/pyenv-virtualenv.git "$PYENV_ROOT/plugins/pyenv-virtualenv"
    fi
    grep -q "pyenv virtualenv-init" "$HOME/.bashrc" 2>/dev/null || echo '\''eval "$(pyenv virtualenv-init -)"'\'' >> "$HOME/.bashrc"
  '
  run_as_user "$user" "$pyenv_init_cmd; eval \"\$(pyenv virtualenv-init -)\"; pyenv virtualenv -f ${python_ver} ${venv_name}"
}

# -----------------------------
# DB setup
# -----------------------------
setup_postgres(){
  local db_name="$1" db_user="$2" db_pass="$3"
  apt_install postgresql postgresql-contrib libpq-dev

  green "Creating PostgreSQL DB/user..."
  sudo -u postgres psql <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${db_user}') THEN
    CREATE ROLE ${db_user} LOGIN PASSWORD '${db_pass}';
  END IF;
END
\$\$;

CREATE DATABASE ${db_name} OWNER ${db_user};
GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};
SQL
  green "PostgreSQL ready."
}

setup_mysql(){
  local db_name="$1" db_user="$2" db_pass="$3"
  apt_install mysql-server default-libmysqlclient-dev

  green "Creating MySQL DB/user..."
  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL
  green "MySQL ready."
}

# -----------------------------
# Reverse proxy
# -----------------------------
setup_nginx_site(){
  local app_name="$1"
  local server_name="$2"   # domain or "_"
  local listen_port="$3"   # 80 or custom

  apt_install nginx
  local site="/etc/nginx/sites-available/${app_name}"
  local enabled="/etc/nginx/sites-enabled/${app_name}"

  cat > "$site" <<EOF
server {
    listen ${listen_port};
    server_name ${server_name};

    client_max_body_size 50M;

    location /static/ {
        alias /srv/${app_name}/app/static/;
    }

    location /media/ {
        alias /srv/${app_name}/app/media/;
    }

    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 900;
    }
}
EOF

  ln -sf "$site" "$enabled"
  rm -f /etc/nginx/sites-enabled/default || true

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
  green "Nginx configured for ${app_name}."
}

install_docker_if_needed(){
  if command -v docker >/dev/null 2>&1; then
    green "Docker already installed."
    return
  fi
  apt_install docker.io docker-compose-plugin
  systemctl enable docker
  systemctl restart docker
  green "Docker installed."
}

setup_nginx_proxy_manager(){
  local app_name="$1"
  local dir="/srv/${app_name}/npm"
  mkdir -p "$dir"
  install_docker_if_needed

  cat > "${dir}/docker-compose.yml" <<'YML'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
YML

  docker compose -f "${dir}/docker-compose.yml" up -d
  green "Nginx Proxy Manager is up."
  echo "NPM UI: http://<server-ip>:81"
  echo "Default login: admin@example.com / changeme (change immediately)"
  echo "Forward your domain to: 127.0.0.1:8001"
}

setup_certbot_for_nginx(){
  local domain="$1"
  apt_install certbot python3-certbot-nginx
  green "Requesting Let's Encrypt cert for: $domain"
  certbot --nginx -d "$domain" --non-interactive --agree-tos -m "admin@${domain}" || {
    yellow "Certbot failed (often DNS not ready). You can retry later:"
    echo "  sudo certbot --nginx -d ${domain}"
  }
}

setup_ufw(){
  apt_install ufw
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  # NPM UI
  ufw allow 81/tcp || true
  if yesno "Enable UFW firewall now?" "n"; then
    ufw --force enable
  fi
  green "UFW status:"
  ufw status verbose || true
}

# -----------------------------
# .env + gunicorn
# -----------------------------
write_env_file(){
  local project_root="$1"
  local app_user="$2"
  local app_group="$3"
  local allowed_hosts="$4"
  local csrf_trusted="$5"
  local db_engine="$6"
  local db_name="$7"
  local db_user="$8"
  local db_pass="$9"
  local db_host="${10}"
  local db_port="${11}"

  local env_path="${project_root}/.env"
  if [[ -f "$env_path" ]]; then
    yellow ".env already exists, leaving as-is: $env_path"
    return
  fi

  local secret_key
  secret_key="$(randpw)"

  cat > "$env_path" <<EOF
DEBUG=0
SECRET_KEY=${secret_key}
ALLOWED_HOSTS=${allowed_hosts}
CSRF_TRUSTED_ORIGINS=${csrf_trusted}

DB_ENGINE=${db_engine}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_pass}
DB_HOST=${db_host}
DB_PORT=${db_port}
EOF

  chown "$app_user:$app_group" "$env_path"
  chmod 600 "$env_path"
  green "Created .env: $env_path"
}

write_gunicorn_service(){
  local service_name="$1"
  local app_user="$2"
  local app_group="$3"
  local project_root="$4"
  local python_exec="$5"
  local wsgi_module="$6"

  local unit="/etc/systemd/system/${service_name}.service"
  cat > "$unit" <<EOF
[Unit]
Description=${service_name}
After=network.target

[Service]
Type=simple
User=${app_user}
Group=${app_group}
WorkingDirectory=${project_root}
EnvironmentFile=${project_root}/.env
Environment=PYTHONUNBUFFERED=1

ExecStart=${python_exec} -m gunicorn ${wsgi_module} --bind 127.0.0.1:8001 --workers 3 --timeout 900

Restart=always
RestartSec=3
KillSignal=SIGINT
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${service_name}.service"
  systemctl restart "${service_name}.service"
  green "Gunicorn service installed: ${service_name}.service"
  systemctl --no-pager -l status "${service_name}.service" || true
}

print_settings_snippet(){
  echo
  green "Add this pattern to settings.py (production):"
  cat <<'PY'
from pathlib import Path
import os
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

DEBUG = os.getenv("DEBUG", "0") == "1"
SECRET_KEY = os.getenv("SECRET_KEY", "unsafe-dev-key")

ALLOWED_HOSTS = [h.strip() for h in os.getenv("ALLOWED_HOSTS", "").split(",") if h.strip()]
CSRF_TRUSTED_ORIGINS = [o.strip() for o in os.getenv("CSRF_TRUSTED_ORIGINS", "").split(",") if o.strip()]

DB_ENGINE = os.getenv("DB_ENGINE", "postgres")
ENGINE_MAP = {
    "postgres": "django.db.backends.postgresql",
    "mysql": "django.db.backends.mysql",
}
DATABASES = {
    "default": {
        "ENGINE": ENGINE_MAP.get(DB_ENGINE, DB_ENGINE),
        "NAME": os.getenv("DB_NAME", ""),
        "USER": os.getenv("DB_USER", ""),
        "PASSWORD": os.getenv("DB_PASSWORD", ""),
        "HOST": os.getenv("DB_HOST", "localhost"),
        "PORT": os.getenv("DB_PORT", ""),
        "CONN_MAX_AGE": 60,
    }
}
PY
}

main(){
  need_root
  green "Django Full Stack Setup (Ubuntu 24.04)"
  echo

  local app_name
  app_name="$(ask "App name (used for /srv/<app>)" "ip_transcoder")"

  local app_user_default="svc_${app_name}"
  local app_user
  app_user="$(ask "Dedicated Linux user" "${app_user_default}")"

  local app_group_default="${app_user}"
  local app_group
  app_group="$(ask "Linux group" "${app_group_default}")"

  ensure_user_group "$app_user" "$app_group"
  setup_dirs "$app_name" "$app_user" "$app_group"

  apt_install python3 python3-venv python3-pip pkg-config

  local base="/srv/${app_name}"
  local project_root="${base}/app"

  # Optional Git clone
  if yesno "Clone a git repo into ${project_root} now?" "n"; then
    apt_install git
    local repo
    repo="$(ask "Git repo URL (https://...)" "")"
    [[ -n "$repo" ]] || die "Repo URL cannot be empty."
    rm -rf "$project_root"/*
    run_as_user "$app_user" "git clone \"$repo\" \"$project_root\""
    chown -R "$app_user:$app_group" "$project_root"
    green "Repo cloned."
  else
    yellow "Skipping git clone. Put your code later in: ${project_root}"
  fi

  # Reverse proxy addressing mode
  echo
  echo "Addressing mode:"
  echo "  1) Domain name"
  echo "  2) IP + Port"
  local addr_mode
  addr_mode="$(ask "Choose 1 or 2" "1")"

  local domain="" server_name="_" listen_port="80"
  local allowed_hosts="" csrf_trusted=""

  if [[ "$addr_mode" == "1" ]]; then
    domain="$(ask "Domain (example: transcoder.example.com)" "")"
    [[ -n "$domain" ]] || die "Domain cannot be empty."
    server_name="$domain"
    listen_port="80"
    allowed_hosts="$domain"
    csrf_trusted="https://${domain},http://${domain}"
  else
    listen_port="$(ask "Public port (example: 8080)" "8080")"
    server_name="_"
    allowed_hosts="127.0.0.1,localhost"
    csrf_trusted="http://127.0.0.1:${listen_port},http://localhost:${listen_port}"
  fi

  # Reverse proxy choice
  echo
  echo "Reverse proxy choice:"
  echo "  1) Nginx Proxy Manager (Docker)"
  echo "  2) Nginx only"
  local proxy_choice
  proxy_choice="$(ask "Choose 1 or 2" "2")"

  if [[ "$proxy_choice" == "1" ]]; then
    setup_nginx_proxy_manager "$app_name"
  else
    setup_nginx_site "$app_name" "$server_name" "$listen_port"
    if [[ "$addr_mode" == "1" ]] && yesno "Install HTTPS via Certbot now (requires DNS pointing to this server)?" "n"; then
      setup_certbot_for_nginx "$domain"
    fi
  fi

  # Firewall option
  if yesno "Configure UFW firewall (OpenSSH + 80/443 + 81)?" "n"; then
    setup_ufw
  fi

  # Database
  echo
  echo "Database:"
  echo "  1) PostgreSQL (recommended)"
  echo "  2) MySQL"
  local db_choice
  db_choice="$(ask "Choose 1 or 2" "1")"

  local db_engine="postgres"
  [[ "$db_choice" == "2" ]] && db_engine="mysql"

  local db_name db_user db_pass db_host db_port
  db_name="$(ask "DB name" "${app_name}_db")"
  db_user="$(ask "DB user" "${app_name}_user")"
  db_pass="$(ask "DB password (empty = auto-generate)" "")"
  [[ -z "$db_pass" ]] && db_pass="$(randpw)"
  db_host="localhost"
  db_port="5432"
  [[ "$db_engine" == "mysql" ]] && db_port="3306"

  if yesno "Install + create DB/user now?" "y"; then
    if [[ "$db_engine" == "postgres" ]]; then
      setup_postgres "$db_name" "$db_user" "$db_pass"
    else
      setup_mysql "$db_name" "$db_user" "$db_pass"
    fi
  else
    yellow "Skipping DB setup."
  fi

  # .env
  write_env_file "$project_root" "$app_user" "$app_group" "$allowed_hosts" "$csrf_trusted" \
    "$db_engine" "$db_name" "$db_user" "$db_pass" "$db_host" "$db_port"

  # Optional pyenv
  echo
  if yesno "Use pyenv for Python version management (recommended if you need 3.10–3.14)?" "y"; then
    if ! pyenv_exists_for_user "$app_user"; then
      if yesno "pyenv not detected for ${app_user}. Install pyenv now?" "y"; then
        install_pyenv_for_user "$app_user"
      else
        yellow "Skipping pyenv."
      fi
    fi

    if pyenv_exists_for_user "$app_user"; then
      show_pyenv_versions "$app_user"
      if yesno "Install a specific Python version with pyenv now?" "y"; then
        local pyver
        pyver="$(ask "Enter version (examples: 3.10.14, 3.11.9, 3.12.7, 3.13.1, 3.14.0)" "3.12.7")"
        install_python_with_pyenv "$app_user" "$pyver"

        if yesno "Create a pyenv virtualenv for this app?" "y"; then
          local venv_name
          venv_name="$(ask "Virtualenv name" "${app_name}")"
          create_pyenv_venv "$app_user" "$pyver" "$venv_name"
          # Use this venv python for services
          local pyexec
          pyexec="$(run_as_user "$app_user" "$pyenv_init_cmd; eval \"\$(pyenv virtualenv-init -)\"; pyenv prefix ${venv_name}")"
          echo "$pyexec" > "/srv/${app_name}/venv_path.txt"
          chown "$app_user:$app_group" "/srv/${app_name}/venv_path.txt"
          green "Saved pyenv venv prefix to /srv/${app_name}/venv_path.txt"
        fi
      fi
    fi
  fi

  # Decide python executable for gunicorn
  local python_exec=""
  if [[ -f "/srv/${app_name}/venv_path.txt" ]]; then
    local prefix
    prefix="$(cat "/srv/${app_name}/venv_path.txt")"
    python_exec="${prefix}/bin/python"
  else
    # fallback: regular venv under /srv/<app>/venv
    local venv_path="/srv/${app_name}/venv"
    if [[ ! -x "${venv_path}/bin/python" ]]; then
      green "Creating standard venv at ${venv_path}"
      run_as_user "$app_user" "python3 -m venv ${venv_path}"
      run_as_user "$app_user" "${venv_path}/bin/pip install -U pip setuptools wheel >/dev/null"
      run_as_user "$app_user" "${venv_path}/bin/pip install -U gunicorn python-dotenv >/dev/null"
    fi
    python_exec="${venv_path}/bin/python"
  fi

  # Install DB driver into python env
  if yesno "Install Django DB driver into your Python environment now?" "y"; then
    if [[ "$db_engine" == "postgres" ]]; then
      run_as_user "$app_user" "${python_exec} -m pip install -U psycopg[binary]"
    else
      run_as_user "$app_user" "${python_exec} -m pip install -U mysqlclient"
    fi
  fi

  # Gunicorn systemd
  local wsgi_module
  wsgi_module="$(ask "WSGI module (example: ip_transcoder.wsgi:application)" "ip_transcoder.wsgi:application")"
  local svc_name="${app_name}_gunicorn"
  if yesno "Create + start systemd gunicorn service (${svc_name}) now?" "y"; then
    write_gunicorn_service "$svc_name" "$app_user" "$app_group" "$project_root" "$python_exec" "$wsgi_module"
  fi

  print_settings_snippet

  echo
  green "Next steps (after code is in /srv/${app_name}/app):"
  echo "  sudo -u ${app_user} -H ${python_exec} -m pip install -r /srv/${app_name}/app/requirements.txt"
  echo "  sudo -u ${app_user} -H ${python_exec} /srv/${app_name}/app/manage.py migrate"
  echo "  sudo -u ${app_user} -H ${python_exec} /srv/${app_name}/app/manage.py collectstatic --noinput"
  echo "  sudo systemctl restart ${svc_name}.service"
  echo
  green "Check logs:"
  echo "  sudo journalctl -u ${svc_name}.service -f"
  echo "  sudo systemctl status ${svc_name}.service"
}

main "$@"
