#!/bin/bash
# deploy_aws.sh — Reconstruye el entorno AWS Academy desde cero
# Uso: bash deploy_aws.sh <DB_PASSWORD> <RENDER_URL>
set -e

DB_PASSWORD=${1:-"wt_secure_2024"}
RENDER_URL=${2:-"placeholder"}

echo "=== [1/6] Actualizando sistema ==="
sudo dnf update -y --quiet

echo "=== [2/6] Instalando PostgreSQL 15 ==="
sudo dnf install -y postgresql15-server postgresql15
sudo postgresql-setup --initdb 2>/dev/null || true
sudo systemctl enable --now postgresql

echo "=== [3/6] Configurando base de datos ==="
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='appuser'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE USER appuser WITH PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='watchtower'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE DATABASE watchtower OWNER appuser;"

sudo -u postgres psql -d watchtower -f - <<'SQL'
CREATE TABLE IF NOT EXISTS monitor (
  id BIGSERIAL PRIMARY KEY,
  nombre TEXT NOT NULL,
  url TEXT NOT NULL,
  intervalo_seg INT DEFAULT 300,
  status_ok INT DEFAULT 200,
  activo BOOLEAN DEFAULT true
);
CREATE TABLE IF NOT EXISTS check_result (
  id BIGSERIAL PRIMARY KEY,
  monitor_id BIGINT REFERENCES monitor(id),
  status_code INT, latencia_ms INT, arriba BOOLEAN,
  checked_at TIMESTAMPTZ DEFAULT now()
);
CREATE TABLE IF NOT EXISTS incidente (
  id BIGSERIAL PRIMARY KEY,
  monitor_id BIGINT REFERENCES monitor(id),
  inicio TIMESTAMPTZ DEFAULT now(), fin TIMESTAMPTZ,
  notificado BOOLEAN DEFAULT false
);
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO appuser;
SQL

echo "=== [4/6] Instalando PgBouncer ==="
if ! command -v pgbouncer &>/dev/null; then
  sudo dnf install -y gcc make libevent-devel openssl-devel pkg-config
  wget -q https://www.pgbouncer.org/downloads/files/1.23.1/pgbouncer-1.23.1.tar.gz
  tar xzf pgbouncer-1.23.1.tar.gz
  cd pgbouncer-1.23.1 && ./configure --prefix=/usr/local --quiet && make -j2 && sudo make install
  cd .. && rm -rf pgbouncer-1.23.1*
fi

sudo mkdir -p /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer
HASH=$(echo -n "${DB_PASSWORD}appuser" | md5sum | cut -d' ' -f1)

sudo tee /etc/pgbouncer/pgbouncer.ini > /dev/null <<EOF
[databases]
watchtower = host=127.0.0.1 port=5432 dbname=watchtower
[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 100
default_pool_size = 20
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid
EOF

sudo bash -c "echo '\"appuser\" \"md5${HASH}\"' > /etc/pgbouncer/userlist.txt"
sudo useradd -r -s /sbin/nologin pgbouncer 2>/dev/null || true
sudo chown -R pgbouncer:pgbouncer /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer

sudo tee /etc/systemd/system/pgbouncer.service > /dev/null <<'EOF'
[Unit]
Description=PgBouncer connection pooler
After=postgresql.service
[Service]
Type=forking
User=pgbouncer
ExecStart=/usr/local/bin/pgbouncer -d /etc/pgbouncer/pgbouncer.ini
PIDFile=/var/run/pgbouncer/pgbouncer.pid
RuntimeDirectory=pgbouncer
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now pgbouncer

echo "=== [5/6] Instalando Nginx ==="
sudo dnf install -y nginx

sudo tee /etc/nginx/conf.d/watchtower.conf > /dev/null <<EOF
upstream backends {
    server 127.0.0.1:3000 max_fails=2 fail_timeout=10s;
    $([ "$RENDER_URL" != "placeholder" ] && echo "server ${RENDER_URL}:443 max_fails=2 fail_timeout=10s;" || echo "# server RENDER_URL:443  -- agregar cuando Ignacio suba Render")
}
server {
    listen 80 default_server;
    server_name _;
    location /health { return 200 'Watchtower OK\n'; add_header Content-Type text/plain; }
    location / {
        proxy_pass http://backends;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_next_upstream error timeout http_502 http_503;
        proxy_connect_timeout 2s;
    }
}
EOF

sudo sed -i '40s/server_name  _;/server_name  localhost_disabled;/' /etc/nginx/nginx.conf 2>/dev/null || true
sudo systemctl enable --now nginx

echo "=== [6/6] Verificación ==="
systemctl is-active postgresql && echo "PostgreSQL OK"
systemctl is-active pgbouncer  && echo "PgBouncer  OK"
systemctl is-active nginx      && echo "Nginx      OK"
curl -s http://localhost/health

echo ""
echo "Deploy completado. IP publica: $(curl -s ifconfig.me)"
