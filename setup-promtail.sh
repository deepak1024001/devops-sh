#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or using sudo."
  exit 1
fi

echo "Downloading Promtail..."
# Download Promtail binary if it doesn't exist
if [ ! -f /usr/local/bin/promtail-linux-amd64 ]; then
    curl -O -L "https://github.com/grafana/loki/releases/download/v3.2.0/promtail-linux-amd64.zip"
    unzip promtail-linux-amd64.zip
    mv promtail-linux-amd64 /usr/local/bin/promtail-linux-amd64
    chmod +x /usr/local/bin/promtail-linux-amd64
    rm promtail-linux-amd64.zip
fi

echo "Starting Promtail Configuration Automation..."

# 1. Create the configuration directory if it doesn't exist
mkdir -p /etc/promtail

# 2. Generate the promtail-local-config.yaml file
echo "📝 Generating /etc/promtail/promtail-local-config.yaml..."
cat << 'EOF' > /etc/promtail/promtail-local-config.yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://100.64.0.8:3100/loki/api/v1/push

scrape_configs:
  - job_name: standard_system_logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: os-syslogs
          host: ${HOSTNAME}
          __path__: /var/log/*.log
          stream: stdout
      - targets:
          - localhost
        labels:
          job: os-syslogs
          host: ${HOSTNAME}
          __path__: /var/log/syslog
          stream: stdout

  - job_name: systemd_kernel_journal
    journal:
      max_age: 12h
      path: /var/log/journal
      labels:
        job: hardware-kernel
        host: ${HOSTNAME}
    relabel_configs:
      - source_labels: ['__journal_transport']
        regex: 'kernel'
        action: keep
EOF

# 3. Create or rewrite the systemd service file with correct flags and environment variables
echo "Configuring systemd service at /etc/systemd/system/promtail.service..."
cat << 'EOF' > /etc/systemd/system/promtail.service
[Unit]
Description=Promtail service
After=network.target

[Service]
Type=simple
User=root
Environment=HOSTNAME=%H
ExecStart=/usr/local/bin/promtail-linux-amd64 -config.file=/etc/promtail/promtail-local-config.yaml -config.expand-env=true
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 4. Set necessary permissions for journald access
echo "Adjusting permissions for systemd-journal..."
usermod -aG systemd-journal root
chmod -R 755 /var/log/journal 2>/dev/null || echo "/var/log/journal not found, skipping chmod."

# 5. Reload systemd daemon and restart the service
echo "Reloading systemd and restarting Promtail..."
systemctl daemon-reload
systemctl enable promtail.service
systemctl restart promtail.service

# 6. Verify status
echo "Deployment complete! Checking service status..."
sleep 2
if systemctl is-active --quiet promtail.service; then
    echo "Promtail is successfully running with your new dynamic configuration!"
else
    echo "Promtail service failed to start. Run 'sudo journalctl -u promtail.service -n 20' to check logs."
fi
