#!/usr/bin/env bash
set -euo pipefail

# django_deploy_wizard.sh
# Interactive server setup helper for Django projects:
# - Choose standard base path (/srv, /opt, /var/www)
# - Clone/pull a git repo into base path
# - Create venv + install dependencies
# - Optional DB install (PostgreSQL or MariaDB/MySQL) + create db/user/password
# - Optional Gunicorn + systemd service
# - Optional Nginx (plain) or Nginx Proxy Manager (Docker) checks/install guidance
#
# Works best on Ubuntu 22.04/24.04.

# 1) See what you already have (paths, nginx, npm, databases)
#       sudo bash django_deploy_wizard.sh status

# 2) Run the full interactive wizard
#       sudo bash django_deploy_wizard.sh install

# 3) Conservative removal helper (systemd unit and/or npm stack only)
#       sudo bash django_deploy_wizard.sh remove


############################
# Helpers
############################
GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; CYAN="\033[0;36m"; NC="\033[0m"

say()  { echo -e "${CYAN}$*${NC}"; }
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run as root (use: sudo bash $0 <command>)"
    exit 1
  fi
}

prompt() {
  # prompt "Question" "default"
  local q="${1}"; local d="${2:-}"
  local ans
  if [[ -n "$d" ]]; then
    read -r -p "$q [$d]: " ans
    ans="${ans:-$d}"
  else
    read -r -p "$q: " ans
  fi
  echo "$ans"
}

confirm() {
  # confirm "Question" default_yes(yes/no)
  local q="$1"; local def="${2:-no}"
  local yn
  if [[ "$def" == "yes" ]]; then
    read -r -p "$q [Y/n]: " yn
    yn="${yn:-Y}"
  else
    read -r -p "$q [y/N]: " yn
    yn="${yn:-N}"
  fi
  [[ "$yn" =~ ^[Yy]$ ]]
}

rand_pw() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_enabled(){ systemctl is-enabled --quiet "$1" 2>/dev/null; }

############################
# Discovery
############################
show_paths() {
  say "Checking common project base paths..."
  local paths=("/srv" "/opt" "/var/www")
  for p in "${paths[@]}"; do
    if [[ -d "$p" ]]; then
      ok "$p exists"
    else
      warn "$p does not exist"
    fi
  done
  echo
  cat <<EOF
Recommended defaults:
- /srv      : clean convention for server apps/services (recommended)
- /opt      : common for third-party apps
- /var/www  : classic web root; can get mixed with static sites
EOF
}

detect_nginx() {
  if have_cmd nginx; then
    ok "Nginx is installed: $(nginx -v 2>&1)"
    if svc_active nginx; then ok "nginx service: active"; else warn "nginx service: not active"; fi
    if svc_enabled nginx; then ok "nginx service: enabled"; else warn "nginx service: not enabled"; fi

    say "Enabled sites ( /etc/nginx/sites-enabled ):"
    if [[ -d /etc/nginx/sites-enabled ]]; then
      ls -lah /etc/nginx/sites-enabled || true
      echo
      say "Quick site state check (nginx -t):"
      if nginx -t >/dev/null 2>&1; then ok "nginx config test OK"; else warn "nginx config test FAILED (run: sudo nginx -t)"; fi
    else
      warn "/etc/nginx/sites-enabled not found (non-Debian layout or nginx not configured)."
    fi
  else
    warn "Nginx is not installed."
  fi
}

detect_docker_npm() {
  if have_cmd docker; then
    ok "Docker is installed: $(docker --version)"
    if svc_active docker; then ok "docker service: active"; else warn "docker service: not active"; fi
  else
    warn "Docker is not installed."
    return 0
  fi

  local npm_ps
  npm_ps="$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | grep -Ei 'nginxproxymanager|jc21/nginx-proxy-manager|nginx-proxy-manager|npm' || true)"
  if [[ -n "$npm_ps" ]]; then
    ok "Nginx Proxy Manager container(s) detected:"
    echo "$npm_ps"
    echo
    warn "Listing Proxy Hosts inside NPM requires querying its internal DB. This script shows container state/ports, and will guide you to the UI."
  else
    warn "No running Nginx Proxy Manager container detected."
  fi
}

detect_databases() {
  say "Checking databases installed/running..."
  if have_cmd psql || systemctl list-unit-files | grep -q '^postgresql\.service'; then
    if svc_active postgresql; then ok "PostgreSQL: active"; else warn "PostgreSQL: installed but not active"; fi
  else
    warn "PostgreSQL: not detected"
  fi

  if have_cmd mysql || systemctl list-unit-files | grep -Eq '^(mysql|mariadb)\.service'; then
    if svc_active mysql; then ok "MySQL: active"; elif svc_active mariadb; then ok "MariaDB: active"; else warn "MySQL/MariaDB: installed but not active"; fi
  else
    warn "MySQL/MariaDB: not detected"
  fi

  echo
  say "Note: Listing existing DB names/users may require root DB access. The script can create a new DB + user for your project."
}

############################
# Installers
############################
apt_update_once() {
  if [[ "${APT_UPDATED:-0}" != "1" ]]; then
    say "Running apt update..."
    apt-get update -y
    APT_UPDATED=1
  fi
}

install_git() {
  if have_cmd git; then ok "git already installed"; return 0; fi
  apt_update_once
  say "Installing git..."
  apt-get install -y git
}

install_python_build() {
  apt_update_once
  say "Installing Python venv + build essentials..."
  apt-get install -y python3-venv python3-pip python3-dev build-essential pkg-config
}

install_nginx() {
  if have_cmd nginx; then ok "nginx already installed"; return 0; fi
  apt_update_once
  say "Installing nginx..."
  apt-get install -y nginx
  systemctl enable --now nginx
}

install_docker() {
  if have_cmd docker; then ok "docker already installed"; return 0; fi
  apt_update_once
  say "Installing docker.io + docker compose plugin (Ubuntu packages)..."
  apt-get install -y docker.io docker-compose-plugin
  systemctl enable --now docker
}

install_npm_compose() {
  local npm_dir="$1"
  mkdir -p "$npm_dir"
  ok "NPM directory: $npm_dir"

  local compose="$npm_dir/docker-compose.yml"
  if [[ -f "$compose" ]]; then
    warn "docker-compose.yml already exists at $compose"
    if ! confirm "Recreate it (overwrite)?" "no"; then
      return 0
    fi
  fi

  cat > "$compose" <<'YML'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
YML

  ok "Wrote: $compose"
  say "Starting NPM (docker compose up -d)..."
  (cd "$npm_dir" && docker compose up -d)
  ok "NPM started."
  say "Open NPM UI: http://SERVER_IP:81"
  warn "Default credentials may change by version; check container logs: docker logs nginx-proxy-manager"
}

install_postgresql() {
  apt_update_once
  say "Installing PostgreSQL..."
  apt-get install -y postgresql postgresql-contrib
  systemctl enable --now postgresql
}

install_mariadb() {
  apt_update_once
  say "Installing MariaDB server (MySQL compatible)..."
  apt-get install -y mariadb-server
  systemctl enable --now mariadb
}

############################
# Project operations
############################
clone_or_update_repo() {
  local base_dir="$1"
  local git_url="$2"
  local project_name="$3"

  mkdir -p "$base_dir"
  ok "Base directory ready: $base_dir"

  local dest="$base_dir/$project_name"
  if [[ -d "$dest/.git" ]]; then
    ok "Existing git repo found at: $dest"
    if confirm "Pull latest changes (git pull)?" "yes"; then
      (cd "$dest" && git pull)
      ok "Updated: $dest"
    else
      warn "Keeping existing repo as-is."
    fi
  elif [[ -d "$dest" ]]; then
    warn "Folder exists but is not a git repo: $dest"
    if confirm "Remove it and re-clone?" "no"; then
      rm -rf "$dest"
      git clone "$git_url" "$dest"
      ok "Cloned: $dest"
    else
      warn "Skipping clone."
    fi
  else
    git clone "$git_url" "$dest"
    ok "Cloned: $dest"
  fi

  echo "$dest"
}

setup_venv_and_deps() {
  local project_dir="$1"
  local run_user="$2"

  say "Setting up Python venv inside project..."
  install_python_build

  local venv_path
  venv_path="$(prompt "Path to venv directory" "$project_dir/.venv")"

  if [[ -d "$venv_path" && -x "$venv_path/bin/python" ]]; then
    ok "Venv already exists: $venv_path"
  else
    say "Creating venv: $venv_path"
    sudo -u "$run_user" python3 -m venv "$venv_path"
    ok "Venv created."
  fi

  say "Upgrading pip/wheel/setuptools..."
  sudo -u "$run_user" "$venv_path/bin/pip" install -U pip wheel setuptools

  local req=""
  if [[ -f "$project_dir/requirements.txt" ]]; then
    req="$project_dir/requirements.txt"
  elif [[ -f "$project_dir/requirements/base.txt" ]]; then
    req="$project_dir/requirements/base.txt"
  fi

  if [[ -n "$req" ]]; then
    ok "Found requirements: $req"
    if confirm "Install requirements now?" "yes"; then
      sudo -u "$run_user" "$venv_path/bin/pip" install -r "$req"
      ok "Requirements installed."
    else
      warn "Skipped installing requirements."
    fi
  else
    warn "No requirements file found. You may need to install dependencies manually."
  fi

  echo "$venv_path"
}

############################
# DB provisioning
############################
provision_postgres_db() {
  local project_slug="$1"
  local db_name db_user db_pass db_port

  db_name="$(prompt "Postgres DB name" "${project_slug}_db")"
  db_user="$(prompt "Postgres DB username" "${project_slug}_user")"
  db_pass="$(prompt "Postgres DB password (leave empty to generate)" "")"
  if [[ -z "$db_pass" ]]; then db_pass="$(rand_pw)"; fi
  db_port="$(prompt "Postgres port" "5432")"

  say "Creating Postgres user/db..."
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${db_user}') THEN
    CREATE ROLE ${db_user} LOGIN PASSWORD '${db_pass}';
  END IF;
END
\$\$;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${db_name}') THEN
    CREATE DATABASE ${db_name} OWNER ${db_user};
  END IF;
END
\$\$;
SQL

  ok "Postgres DB provisioned."
  cat <<EOF

=== PostgreSQL connection info ===
ENGINE: django.db.backends.postgresql
HOST:   127.0.0.1
PORT:   ${db_port}
NAME:   ${db_name}
USER:   ${db_user}
PASS:   ${db_pass}
=================================
EOF
}

provision_mariadb_db() {
  local project_slug="$1"
  local db_name db_user db_pass db_port

  db_name="$(prompt "MySQL/MariaDB DB name" "${project_slug}_db")"
  db_user="$(prompt "MySQL/MariaDB username" "${project_slug}_user")"
  db_pass="$(prompt "MySQL/MariaDB password (leave empty to generate)" "")"
  if [[ -z "$db_pass" ]]; then db_pass="$(rand_pw)"; fi
  db_port="$(prompt "MySQL/MariaDB port" "3306")"

  say "Creating MySQL/MariaDB user/db..."
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL

  ok "MySQL/MariaDB DB provisioned."
  cat <<EOF

=== MySQL/MariaDB connection info ===
ENGINE: django.db.backends.mysql
HOST:   127.0.0.1
PORT:   ${db_port}
NAME:   ${db_name}
USER:   ${db_user}
PASS:   ${db_pass}
====================================
EOF
}

############################
# Gunicorn + systemd
############################
create_systemd_service() {
  local service_name="$1"
  local run_user="$2"
  local project_dir="$3"
  local venv_path="$4"
  local django_settings="$5"
  local bind_addr="$6"
  local wsgi_module="$7"
  local workers="$8"

  local unit="/etc/systemd/system/${service_name}.service"
  if [[ -f "$unit" ]]; then
    warn "Service file already exists: $unit"
    if ! confirm "Overwrite it?" "no"; then
      return 0
    fi
  fi

  cat > "$unit" <<EOF
[Unit]
Description=${service_name} (Gunicorn for Django)
After=network.target

[Service]
Type=simple
User=${run_user}
WorkingDirectory=${project_dir}
Environment=DJANGO_SETTINGS_MODULE=${django_settings}
Environment=PYTHONUNBUFFERED=1
ExecStart=${venv_path}/bin/gunicorn ${wsgi_module} --bind ${bind_addr} --workers ${workers} --timeout 900
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  ok "Wrote unit: $unit"
  systemctl daemon-reload
  systemctl enable --now "${service_name}.service"
  ok "Service started: ${service_name}.service"
}

############################
# Reverse proxy guidance
############################
guide_domain_vs_ip() {
  cat <<'EOF'

Domain vs IP:Port (real-world)
- Domain mode (recommended): users access https://example.com (no :port shown)
  * Reverse proxy listens on 80/443 and forwards to your app on an internal port (e.g., 127.0.0.1:8001).
- IP-only mode: users often access http://SERVER_IP:8001 (port shown),
  OR you can proxy on port 80 so they can use http://SERVER_IP (no port).
- VLC-only note for UDP tests: VLC uses udp://@IP:PORT to listen. Production receivers use udp://IP:PORT.

EOF
}

guide_nginx_site() {
  local server_name="$1"
  local listen_port="$2"
  local upstream="$3"
  local site_name="$4"

  cat <<EOF

--- Suggested Nginx site config (Debian/Ubuntu layout) ---
File: /etc/nginx/sites-available/${site_name}

server {
    listen ${listen_port};
    server_name ${server_name};

    client_max_body_size 50M;

    location / {
        proxy_pass ${upstream};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

Enable:
  sudo ln -sf /etc/nginx/sites-available/${site_name} /etc/nginx/sites-enabled/${site_name}
  sudo nginx -t && sudo systemctl reload nginx

EOF
}

############################
# Main flow
############################
cmd_status() {
  show_paths
  echo
  detect_nginx
  echo
  detect_docker_npm
  echo
  detect_databases
  echo
  guide_domain_vs_ip
}

cmd_install() {
  need_root
  echo
  show_paths
  echo

  local base_choice
  base_choice="$(prompt "Choose base directory for Django projects (/srv, /opt, /var/www, or custom)" "/srv")"

  if [[ ! -d "$base_choice" ]]; then
    warn "$base_choice does not exist."
    if confirm "Create it now?" "yes"; then
      mkdir -p "$base_choice"
      ok "Created: $base_choice"
    else
      err "Cannot continue without a base directory."
      exit 1
    fi
  fi

  echo
  install_git
  local git_url
  git_url="$(prompt "Git repository URL to clone" "")"
  if [[ -z "$git_url" ]]; then
    err "Git URL is required."
    exit 1
  fi

  local derived
  derived="$(basename "${git_url%.git}")"
  local project_name
  project_name="$(prompt "Project folder name" "$derived")"
  local project_dir
  project_dir="$(clone_or_update_repo "$base_choice" "$git_url" "$project_name")"

  local run_user
  run_user="$(prompt "Run Django/Gunicorn as user" "${SUDO_USER:-root}")"

  echo
  local venv_path
  venv_path="$(setup_venv_and_deps "$project_dir" "$run_user")"

  echo
  detect_databases
  if confirm "Do you want to install/provision a database for this project now?" "yes"; then
    echo "Choose DB:"
    echo "  1) PostgreSQL (recommended for Django)"
    echo "  2) MySQL/MariaDB"
    echo "  3) Skip"
    local db_choice
    db_choice="$(prompt "Select 1/2/3" "1")"
    local slug
    slug="$(echo "$project_name" | tr -cd 'A-Za-z0-9_' | tr '[:upper:]' '[:lower:]')"

    case "$db_choice" in
      1)
        if ! have_cmd psql; then
          if confirm "PostgreSQL not detected. Install PostgreSQL?" "yes"; then
            install_postgresql
          else
            warn "Skipping PostgreSQL installation."
          fi
        fi
        if have_cmd psql; then
          provision_postgres_db "$slug"
        else
          warn "PostgreSQL not available; skipping provisioning."
        fi
        ;;
      2)
        if ! have_cmd mysql; then
          if confirm "MySQL/MariaDB not detected. Install MariaDB server?" "yes"; then
            install_mariadb
          else
            warn "Skipping MariaDB installation."
          fi
        fi
        if have_cmd mysql; then
          provision_mariadb_db "$slug"
        else
          warn "MySQL/MariaDB not available; skipping provisioning."
        fi
        ;;
      *)
        warn "DB provisioning skipped."
        ;;
    esac
  else
    warn "DB step skipped."
  fi

  echo
  if confirm "Do you want to create a Gunicorn systemd service for this Django project?" "yes"; then
    local service_name django_settings wsgi_module bind_addr workers
    service_name="$(prompt "Systemd service name" "${project_name}_gunicorn")"
    django_settings="$(prompt "DJANGO_SETTINGS_MODULE" "${project_name}.settings")"
    wsgi_module="$(prompt "WSGI module (e.g. myproj.wsgi:application)" "${project_name}.wsgi:application")"
    bind_addr="$(prompt "Gunicorn bind address (use 127.0.0.1:8001 if using reverse proxy)" "127.0.0.1:8001")"
    workers="$(prompt "Gunicorn workers" "3")"

    if ! sudo -u "$run_user" "$venv_path/bin/python" -c "import gunicorn" >/dev/null 2>&1; then
      say "Installing gunicorn into venv..."
      sudo -u "$run_user" "$venv_path/bin/pip" install gunicorn
    fi

    create_systemd_service "$service_name" "$run_user" "$project_dir" "$venv_path" "$django_settings" "$bind_addr" "$wsgi_module" "$workers"

    cat <<EOF

Service controls:
  sudo systemctl status ${service_name}.service
  sudo systemctl restart ${service_name}.service
  sudo journalctl -u ${service_name}.service -f

EOF
  else
    warn "Gunicorn systemd step skipped."
  fi

  echo
  detect_nginx
  detect_docker_npm
  guide_domain_vs_ip

  if confirm "Do you want to configure a reverse proxy now (NPM or Nginx)?" "yes"; then
    echo "Choose reverse proxy:"
    echo "  1) Nginx Proxy Manager (Docker + UI)"
    echo "  2) Plain Nginx (config files)"
    echo "  3) Skip"
    local px_choice
    px_choice="$(prompt "Select 1/2/3" "1")"

    case "$px_choice" in
      1)
        if ! have_cmd docker; then
          warn "Docker is not installed."
          if confirm "Install Docker + Compose plugin now?" "yes"; then
            install_docker
          else
            warn "Skipping NPM installation."
          fi
        fi
        if have_cmd docker; then
          local npm_dir
          npm_dir="$(prompt "Where to install NPM compose stack?" "/srv/npm")"
          install_npm_compose "$npm_dir"

          say "NPM guidance:"
          echo "  - If using DOMAIN: add Proxy Host: domain -> forward to http://127.0.0.1:8001 (or your bind)"
          echo "  - SSL: request Let's Encrypt (requires DNS pointed + ports 80/443 reachable)"
        fi
        ;;
      2)
        if ! have_cmd nginx; then
          warn "Nginx is not installed."
          if confirm "Install Nginx now?" "yes"; then
            install_nginx
          else
            warn "Skipping Nginx installation."
          fi
        fi
        if have_cmd nginx; then
          echo "Access mode:"
          echo "  1) Domain (recommended: 80/443, no port shown)"
          echo "  2) IP-only (you can use 80 or a custom port)"
          local mode
          mode="$(prompt "Select 1/2" "1")"

          local upstream
          upstream="$(prompt "Upstream app URL (e.g. http://127.0.0.1:8001)" "http://127.0.0.1:8001")"
          local site_name
          site_name="$(prompt "Nginx site config name" "${project_name}.conf")"

          local server_name listen_port
          if [[ "$mode" == "1" ]]; then
            server_name="$(prompt "Domain name (server_name)" "example.com")"
            listen_port="$(prompt "Listen port" "80")"
          else
            server_name="_"
            listen_port="$(prompt "Listen port (80 for no port in URL, or custom)" "80")"
          fi

          guide_nginx_site "$server_name" "$listen_port" "$upstream" "$site_name"

          if confirm "Create the Nginx site file now?" "no"; then
            local avail="/etc/nginx/sites-available/${site_name}"
            cat > "$avail" <<EOF
server {
    listen ${listen_port};
    server_name ${server_name};

    client_max_body_size 50M;

    location / {
        proxy_pass ${upstream};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
            ok "Wrote: $avail"
            if confirm "Enable this site (symlink + reload nginx)?" "yes"; then
              ln -sf "$avail" "/etc/nginx/sites-enabled/${site_name}"
              nginx -t
              systemctl reload nginx
              ok "Site enabled and nginx reloaded."
            fi
          else
            warn "Site file not created. Use the snippet above when ready."
          fi

          warn "SSL note: For domains, use NPM or Certbot later for Let's Encrypt."
        fi
        ;;
      *)
        warn "Reverse proxy skipped."
        ;;
    esac
  else
    warn "Reverse proxy step skipped."
  fi

  echo
  ok "Done. Summary:"
  echo "  - Project dir: $project_dir"
  echo "  - Venv:        $venv_path"
  echo "  - Next: configure Django settings.py with DB info (printed above if you provisioned one)."
  echo
}

cmd_remove() {
  need_root
  warn "Remove mode is intentionally conservative."
  echo "This script can remove:"
  echo " - a systemd service (you provide the service name)"
  echo " - an NPM docker compose stack directory (you provide path)"
  echo "It will NOT delete your project directory unless you do it yourself."
  echo

  if confirm "Remove a systemd service?" "no"; then
    local svc
    svc="$(prompt "Service name (without .service)" "")"
    if [[ -n "$svc" ]]; then
      systemctl stop "${svc}.service" 2>/dev/null || true
      systemctl disable "${svc}.service" 2>/dev/null || true
      rm -f "/etc/systemd/system/${svc}.service"
      systemctl daemon-reload
      ok "Removed systemd unit: ${svc}.service"
    fi
  fi

  if confirm "Remove an NPM compose stack (docker compose down)?" "no"; then
    local npm_dir
    npm_dir="$(prompt "Path to NPM directory (contains docker-compose.yml)" "/srv/npm")"
    if [[ -f "$npm_dir/docker-compose.yml" ]]; then
      (cd "$npm_dir" && docker compose down) || true
      ok "Stopped NPM stack."
      if confirm "Delete NPM directory $npm_dir ?" "no"; then
        rm -rf "$npm_dir"
        ok "Deleted: $npm_dir"
      fi
    else
      warn "No docker-compose.yml found at $npm_dir"
    fi
  fi
}

usage() {
  cat <<EOF
Usage:
  sudo bash $0 status
  sudo bash $0 install
  sudo bash $0 remove

status  - Detect existing nginx/NPM/databases and show recommended practices
install - Interactive wizard: base path, clone project, venv, optional DB, optional gunicorn/systemd, optional proxy
remove  - Conservative remover for systemd unit and/or NPM stack (no project deletion)
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    status) cmd_status ;;
    install) cmd_install ;;
    remove) cmd_remove ;;
    ""|-h|--help|help) usage ;;
    *) err "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
