#!/usr/bin/env bash
# Run by EC2 cloud-init after SOURCE_BUCKET and SOURCE_KEY have been exported.
set -Eeuo pipefail
exec > >(tee -a /var/log/canvas-bootstrap.log) 2>&1
trap 'echo "FAILED at line $LINENO"; touch /var/lib/canvas-bootstrap-failed' ERR
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y ca-certificates curl git awscli python3 unzip
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable' > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu

if ! swapon --show | grep -q /swapfile; then
  fallocate -l 8G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

mkdir -p /home/ubuntu/canvas-lms
downloaded=false
for attempt in $(seq 1 90); do
  if aws s3 cp "s3://$SOURCE_BUCKET/$SOURCE_KEY" /tmp/canvas-source.tar.gz --only-show-errors; then
    downloaded=true
    break
  fi
  sleep 10
done
test "$downloaded" = true
tar -xzf /tmp/canvas-source.tar.gz -C /home/ubuntu/canvas-lms
cd /home/ubuntu/canvas-lms
cp docker-compose/config/*.yml config/
cp config/docker-compose.override.yml.example docker-compose.override.yml

python3 - <<'PY'
import secrets
from pathlib import Path
Path('.env').write_text(
    'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.local.aws.yml\n'
    'COMPOSE_PROJECT_NAME=canvas\n'
    f'POSTGRES_PASSWORD={secrets.token_hex(32)}\n'
    f'ENCRYPTION_KEY={secrets.token_hex(32)}\n'
    f'JWT_ENCRYPTION_KEY={secrets.token_hex(32)}\n'
)
Path('/home/ubuntu/canvas-admin.env').write_text(
    'CANVAS_LMS_ADMIN_EMAIL=admin@canvas.local\n'
    f'CANVAS_LMS_ADMIN_PASSWORD={secrets.token_urlsafe(24)}\n'
    'CANVAS_LMS_ACCOUNT_NAME="Canvas Development"\n'
    'CANVAS_LMS_STATS_COLLECTION=opt_out\n'
)
PY
chmod 600 .env /home/ubuntu/canvas-admin.env
chown ubuntu:ubuntu /home/ubuntu/canvas-admin.env

cat > config/domain.yml <<'YAML'
development:
  domain: "localhost:8080"
  ssl: false
test:
  domain: localhost
production:
  domain: "localhost:8080"
  ssl: false
YAML
cat > config/security.yml <<'YAML'
development: &security
  encryption_key: <%= ENV.fetch("ENCRYPTION_KEY") %>
  jwt_encryption_keys:
    - <%= ENV.fetch("JWT_ENCRYPTION_KEY") %>
  lti_iss: 'https://canvas.instructure.com'
test:
  <<: *security
production:
  <<: *security
YAML
cat > docker-compose.local.aws.yml <<'YAML'
services:
  web:
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:80"
    environment: &aws_environment
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      ENCRYPTION_KEY: ${ENCRYPTION_KEY}
      JWT_ENCRYPTION_KEY: ${JWT_ENCRYPTION_KEY}
      RAILS_ENV: development
      HTTPS_METHOD: noredirect
      VIRTUAL_HOST: localhost
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
  jobs:
    restart: unless-stopped
    environment: *aws_environment
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
  postgres:
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 30
  redis:
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
volumes:
  redis_data: {}
YAML

# The upstream image uses UID/GID 9999 for bind-mounted application files.
groupadd -g 9999 canvas-dev || true
usermod -aG canvas-dev ubuntu
chown -R 9999:9999 /home/ubuntu/canvas-lms
chmod -R g+rwX /home/ubuntu/canvas-lms
docker compose config --quiet
docker compose build web postgres
docker compose up -d postgres redis
docker compose run --rm web ./script/install_assets.sh
set -a
source /home/ubuntu/canvas-admin.env
set +a
docker compose run --rm \
  -e CANVAS_LMS_ADMIN_EMAIL -e CANVAS_LMS_ADMIN_PASSWORD \
  -e CANVAS_LMS_ACCOUNT_NAME -e CANVAS_LMS_STATS_COLLECTION \
  web bundle exec rake db:initial_setup
unset CANVAS_LMS_ADMIN_PASSWORD
docker compose up -d web jobs
for attempt in $(seq 1 60); do
  if curl --fail --silent -o /tmp/canvas-login.html http://localhost:8080/login/canvas; then
    touch /var/lib/canvas-bootstrap-ready
    echo 'Canvas is ready on localhost:8080 (access through Session Manager).'
    exit 0
  fi
  sleep 10
done
echo 'Canvas did not pass the login-page health check.'
exit 1
