#!/bin/sh

# Function to grab SSM parameters
aws_get_parameter() {
    aws ssm --region ${REGION} get-parameter \
        --name "${PARAMETER_PATH}/$1" \
        --with-decryption \
        --output text \
        --query Parameter.Value 2>/dev/null
}

# Enable auto updates
echo "Enabling auto updates"
echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true \
    | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades

# Installing decK
# https://github.com/hbagdi/deck
curl -sL https://github.com/hbagdi/deck/releases/download/v${DECK_VERSION}/deck_${DECK_VERSION}_linux_amd64.tar.gz \
    -o deck.tar.gz
tar zxf deck.tar.gz deck
sudo mv deck /usr/local/bin
sudo chown root:kong /usr/local/bin/deck
sudo chmod 755 /usr/local/bin/deck

# Install Kong dependencies
sudo apt install libc-dev-bin linux-libc-dev libcrypt-dev libc-dev zlib1g-dev

# Install Kong
echo "Installing Kong"
curl -sL ${DOWNLOAD_URL} \
    -o kong.deb
dpkg -i kong.deb

# Setup database
echo "Setting up Kong database"
PGPASSWORD=$(aws_get_parameter "db/password/master")
DB_HOST=$(aws_get_parameter "db/host")
DB_NAME=$(aws_get_parameter "db/name")
DB_PASSWORD=$(aws_get_parameter "db/password")
export PGPASSWORD

RESULT=$(psql --host $DB_HOST --username root \
    --tuples-only --no-align postgres \
    <<EOF
SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'
EOF
)

if [ $? != 0 ]; then
    echo "Error: Database connection failed, please configure manually"
    exit 1
fi

echo $RESULT | grep -q 1
if [ $? != 0 ]; then
    psql --host $DB_HOST --username root postgres <<EOF
CREATE USER ${DB_USER} WITH PASSWORD '$DB_PASSWORD';
GRANT ${DB_USER} TO root;
CREATE DATABASE $DB_NAME OWNER = ${DB_USER};
EOF
fi
unset PGPASSWORD

# Setup Configuration file
cat <<EOF > /etc/kong/kong.conf
# kong.conf, Kong configuration file
# Written by Dennis Kelly <dennisk@zillowgroup.com>
# Updated by Dennis Kelly <dennis.kelly@konghq.com>
#
# 2020-01-23: Support for EE Kong Manager Auth
# 2019-09-30: Support for 1.x releases and Dev Portal
# 2018-03-13: Support for 0.12 and load balancing
# 2017-06-20: Initial release
#
# Notes:
#   - See kong.conf.default for further information

# Database settings
database = postgres 
pg_host = $DB_HOST
pg_user = ${DB_USER}
pg_password = $DB_PASSWORD
pg_database = $DB_NAME

# Load balancer headers
real_ip_header = X-Forwarded-For
trusted_ips = 0.0.0.0/0

# SSL terminiation is performed by load balancers
proxy_listen = 0.0.0.0:8000
# For /status to load balancers
admin_listen = 0.0.0.0:8001
EOF
chmod 640 /etc/kong/kong.conf
chgrp kong /etc/kong/kong.conf

chown root:kong /usr/local/kong
chmod 2775 /usr/local/kong

# Initialize Kong
echo "Initializing Kong"
sudo -u kong kong migrations bootstrap

cat <<'EOF' > /usr/local/kong/nginx.conf
worker_processes auto;
daemon off;

pid pids/nginx.pid;
error_log logs/error.log notice;

worker_rlimit_nofile 65536;

events {
    worker_connections 8192;
    multi_accept on;
}

http {
    include nginx-kong.conf;
}
EOF
chown root:kong /usr/local/kong/nginx.conf

# Log rotation
cat <<'EOF' > /etc/logrotate.d/kong
/usr/local/kong/logs/*.log {
  rotate 14
  daily
  compress
  missingok
  notifempty
  create 640 kong kong
  sharedscripts

  postrotate
    /usr/bin/sv 1 /etc/sv/kong
  endscript
}
EOF

# Start Kong under supervision
echo "Starting Kong under supervision"
mkdir -p /etc/sv/kong /etc/sv/kong/log

cat <<'EOF' > /etc/sv/kong/run
#!/bin/sh -e
exec 2>&1

ulimit -n 65536
sudo -u kong kong prepare
exec chpst -u kong /usr/local/openresty/nginx/sbin/nginx -p /usr/local/kong -c nginx.conf
EOF

cat <<'EOF' > /etc/sv/kong/log/run
#!/bin/sh -e

[ -d /var/log/kong ] || mkdir -p /var/log/kong
chown kong:kong /var/log/kong

exec chpst -u kong /usr/bin/svlogd -tt /var/log/kong
EOF
chmod 744 /etc/sv/kong/run /etc/sv/kong/log/run

cd /etc/service
ln -s /etc/sv/kong

# Verify Admin API is up
RUNNING=0
for I in 1 2 3 4 5 6 7 8 9; do
    curl -s -I http://localhost:8001/status | grep -q "200 OK"
    if [ $? = 0 ]; then
        RUNNING=1
        break
    fi
    sleep 1
done

if [ $RUNNING = 0 ]; then
    echo "Cannot connect to admin API, avoiding further configuration."
    exit 1
fi

# Enable healthchecks using a kong endpoint
curl -s -I http://localhost:8000/status | grep -q "200 OK"
if [ $? != 0 ]; then
    echo "Configuring healthcheck"
    curl -s -X POST http://localhost:8001/services \
        -d name=status \
        -d host=localhost \
        -d port=8001 \
        -d path=/status > /dev/null
    curl -s -X POST http://localhost:8001/services/status/routes \
        -d name=status \
        -d 'methods[]=HEAD' \
        -d 'methods[]=GET' \
        -d 'paths[]=/status' > /dev/null
    curl -s -X POST http://localhost:8001/services/status/plugins \
        -d name=ip-restriction \
        -d "config.whitelist=127.0.0.1" \
        -d "config.whitelist=${VPC_CIDR_BLOCK}" > /dev/null
fi
