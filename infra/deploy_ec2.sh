#!/bin/bash
# deploy_ec2.sh — Deploy completo en EC2 (llamar desde local)
# Uso: bash deploy_ec2.sh <EC2_IP> <DB_PASSWORD>
set -e

EC2_IP=$1
DB_PASSWORD=${2:-"wt_secure_2024"}
PEM="$HOME/Downloads/labsuser.pem"
SSH="ssh -i $PEM -o StrictHostKeyChecking=no ec2-user@$EC2_IP"
SCP="scp -i $PEM -o StrictHostKeyChecking=no"

echo "=== [1/4] Copiando backend a EC2 ==="
$SSH "sudo mkdir -p /tmp/backend && sudo chown ec2-user /tmp/backend"
$SCP -r "$(dirname $0)/../backend/"* "ec2-user@$EC2_IP:/tmp/backend/"
$SCP "$(dirname $0)/nginx_two_backends.conf" "ec2-user@$EC2_IP:/tmp/"

echo "=== [2/4] Instalando Python y dependencias ==="
$SSH "
  sudo dnf install -y python3-pip python3 --quiet
  sudo mkdir -p /opt/watchtower
  sudo chown ec2-user /opt/watchtower
  cp -r /tmp/backend/* /opt/watchtower/
  cd /opt/watchtower && pip3 install -r requirements.txt --quiet
"

echo "=== [3/4] Creando archivo de entorno ==="
$SSH "cat > /opt/watchtower/.env << 'ENVEOF'
DB_HOST=localhost
DB_PORT=6432
DB_NAME=watchtower
DB_USER=appuser
DB_PASSWORD=$DB_PASSWORD
ENVEOF"

echo "=== [4/4] Iniciando backends y actualizando Nginx ==="
$SSH "
  # Detener instancias anteriores
  pkill -f 'uvicorn main:app' 2>/dev/null || true
  sleep 1

  # Backend-1 puerto 3000
  cd /opt/watchtower
  INSTANCE_NAME=backend-1 DB_HOST=localhost DB_PORT=6432 \
  DB_NAME=watchtower DB_USER=appuser DB_PASSWORD=$DB_PASSWORD \
  nohup python3 -m uvicorn main:app --host localhost --port 3000 \
    --log-level warning > /tmp/backend1.log 2>&1 &

  # Backend-2 puerto 3001
  INSTANCE_NAME=backend-2 DB_HOST=localhost DB_PORT=6432 \
  DB_NAME=watchtower DB_USER=appuser DB_PASSWORD=$DB_PASSWORD \
  nohup python3 -m uvicorn main:app --host localhost --port 3001 \
    --log-level warning > /tmp/backend2.log 2>&1 &

  sleep 3

  # Actualizar Nginx
  sudo cp /tmp/nginx_two_backends.conf /etc/nginx/conf.d/watchtower.conf
  sudo nginx -t && sudo systemctl reload nginx

  # Verificacion final
  echo '--- Backends ---'
  curl -s http://localhost:3000/health
  curl -s http://localhost:3001/health
  echo '--- Nginx ---'
  curl -s http://localhost/health
"

echo ""
echo "Deploy completado. Prueba publica: http://$EC2_IP/health"
echo "Instancia servida: http://$EC2_IP/health (alterna entre backend-1 y backend-2)"
