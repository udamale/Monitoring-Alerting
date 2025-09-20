#!/bin/bash
set -e
echo "=============================="
echo " Installing Promethous-grafana-Alertmanager--Node Exporter"
echo "=============================="

# ============ 1. Update System ============
sudo apt update && apt upgrade -y

# ============ 2. Install Prometheus ============
sudo useradd --no-create-home --shell /bin/false prometheus
sudo mkdir /etc/prometheus /var/lib/prometheus
sudo chown prometheus:prometheus /etc/prometheus /var/lib/prometheus

sudo cd /tmp
sudo curl -LO https://github.com/prometheus/prometheus/releases/download/v2.55.1/prometheus-2.55.1.linux-amd64.tar.gz
sudo tar -xvf prometheus-2.55.1.linux-amd64.tar.gz
sudo cd prometheus-2.55.1.linux-amd64

sudo cp prometheus promtool /usr/local/bin/
sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool

sudo cp -r consoles/ console_libraries/ /etc/prometheus/
sudo cp prometheus.yml /etc/prometheus/prometheus.yml
sudo chown -R prometheus:prometheus /etc/prometheus/*

sudo cat <<EOF >/etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \\
  --config.file=/etc/prometheus/prometheus.yml \\
  --storage.tsdb.path=/var/lib/prometheus/ \\
  --web.console.templates=/etc/prometheus/consoles \\
  --web.console.libraries=/etc/prometheus/console_libraries
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl enable --now prometheus

# ============ 3. Install Grafana ============
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y "deb https://packages.grafana.com/oss/deb stable main"
sudo wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
sudo apt update
sudo apt install grafana -y
sudo systemctl enable --now grafana-server

# ============ 4. Install Alertmanager ============
sudo cd /tmp
sudo curl -LO https://github.com/prometheus/alertmanager/releases/download/v0.27.0/alertmanager-0.27.0.linux-amd64.tar.gz
sudo tar -xvf alertmanager-0.27.0.linux-amd64.tar.gz
sudo cd alertmanager-0.27.0.linux-amd64

sudo cp alertmanager amtool /usr/local/bin/
sudo mkdir /etc/alertmanager /var/lib/alertmanager
sudo cp alertmanager.yml /etc/alertmanager/
sudo chown -R prometheus:prometheus /etc/alertmanager /var/lib/alertmanager

sudo cat <<EOF >/etc/systemd/system/alertmanager.service
[Unit]
Description=Alertmanager
After=network.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/alertmanager \\
  --config.file=/etc/alertmanager/alertmanager.yml \\
  --storage.path=/var/lib/alertmanager/
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl enable --now alertmanager

# ============ 5. Configure Prometheus Alerts ============
sudo cat <<EOF >/etc/prometheus/alert.rules.yml
groups:
  - name: example-alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Instance {{ \$labels.instance }} is down"
          description: "Prometheus target {{ \$labels.instance }} has been unreachable for more than 1 minute."

      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 40
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "High CPU usage detected on {{ \$labels.instance }}"
          description: "CPU usage > 40% for more than 2 minutes. VALUE = {{ \$value }}%"

      - alert: UnauthorizedRequests
        expr: increase(http_requests_total{status=~"401|403"}[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Unauthorized requests on {{ \$labels.instance }}"
          description: "Detected unauthorized (401/403) requests in the past 5 minutes."
EOF

# Link rules into Prometheus config
#sed -i '/^global:/a \
#rule_files:\n  - "alert.rules.yml"\n' /etc/prometheus/prometheus.yml

#systemctl restart prometheus

# ============ 6. PagerDuty Integration ============
sudo cat <<EOF >/etc/alertmanager/alertmanager.yml
route:
  receiver: pagerduty
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h

receivers:
  - name: pagerduty
    pagerduty_configs:
      - routing_key: "d9ad2ab446a2400cd0943cff3320e758"
        severity: "critical"
EOF

sudo systemctl restart alertmanager

# ============ 7. Install Node Exporter ============
sudo useradd --no-create-home --shell /bin/false node_exporter
sudo cd /tmp
sudo curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
sudo tar -xvf node_exporter-1.8.2.linux-amd64.tar.gz
sudo cd node_exporter-1.8.2.linux-amd64
sudo cp node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

sudo cat <<EOF >/etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl enable --now node_exporter

# ============ 8. Add Node Exporter to Prometheus ============
sudo cat <<'EOF' >/etc/prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]
    # EC2-discovered Alertmanagers
    - ec2_sd_configs:
        - region: us-east-1           # Replace with your AWS region
          port: 9093
          filters:
           # - name: "tag:Role"
            #  values: ["alertmanager"]
            - name: "tag:Name"
              values: ["node-server"]        # optional: only pick prod Alertmanagers
      relabel_configs:
        - source_labels: [__meta_ec2_private_ip]
          regex: (.*)
          target_label: __address__
          replacement: "$1:9093"

    # Local fallback Alertmanager
    
rule_files:
  - "alert.rules.yml"
  # - "second_rules.yml"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9100"]

  - job_name: "ec2-node-exporters"
    ec2_sd_configs:
      - region: us-east-1           # Replace with your AWS region
        port: 9100
        filters:
          - name: "tag:Name"
            values: ["node-server"]
    relabel_configs:
      - source_labels: [__meta_ec2_private_ip]
        regex: (.*)
        target_label: __address__
        replacement: "$1:9100"
EOF

sudo systemctl restart prometheus
sudo apt update && apt upgrade -y

echo "=============================="
echo " Installation Completed ✅"
echo "=============================="

