#!/bin/bash
# start_backends.sh — Inicia Backend-1 y Backend-2 en EC2
set -e

APP_DIR="/opt/watchtower"

if ! command -v pip3 &>/dev/null; then
  sudo dnf install -y python3-pip
fi

sudo mkdir -p $APP_DIR
sudo chown ec2-user:ec2-user $APP_DIR
cp -r /tmp/backend/* $APP_DIR/

cd $APP_DIR
pip3 install -r requirements.txt --quiet

source /opt/watchtower/.env

pkill -f "uvicorn main:app" 2>/dev/null || true
sleep 1

# Backend-1 puerto 3000
INSTANCE_NAME=backend-1 DB_HOST=$DB_HOST DB_PORT=$DB_PORT \
DB_NAME=$DB_NAME DB_USER=$DB_USER DB_PASSWORD=$DB_PASSWORD \
nohup python3 -m uvicorn main:app --host localhost --port 3000 \
  --log-level warning > /var/log/backend1.log 2>&1 &
echo "Backend-1 PID: $!"

# Backend-2 puerto 3001
INSTANCE_NAME=backend-2 DB_HOST=$DB_HOST DB_PORT=$DB_PORT \
DB_NAME=$DB_NAME DB_USER=$DB_USER DB_PASSWORD=$DB_PASSWORD \
nohup python3 -m uvicorn main:app --host localhost --port 3001 \
  --log-level warning > /var/log/backend2.log 2>&1 &
echo "Backend-2 PID: $!"

sleep 2
curl -s http://localhost:3000/health && echo " <- Backend-1 OK"
curl -s http://localhost:3001/health && echo " <- Backend-2 OK"
