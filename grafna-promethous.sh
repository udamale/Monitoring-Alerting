#!/bin/bash
set -e

# ============ 1. Update System ============
sudo apt update && apt upgrade -y

# ============ 2. Install Prometheus ============
useradd --no-create-home --shell /bin/false prometheus
mkdir /etc/prometheus /var/lib/prometheus
chown prometheus:prometheus /etc/prometheus /var/lib/prometheus

cd /tmp
curl -LO https://github.com/prometheus/prometheus/releases/download/v2.55.1/prometheus-2.55.1.linux-amd64.tar.gz
tar -xvf prometheus-2.55.1.linux-amd64.tar.gz
cd prometheus-2.55.1.linux-amd64

cp prometheus promtool /usr/local/bin/
chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool

cp -r consoles/ console_libraries/ /etc/prometheus/
cp prometheus.yml /etc/prometheus/prometheus.yml
chown -R prometheus:prometheus /etc/prometheus/*

cat <<EOF >/etc/systemd/system/prometheus.service
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

systemctl daemon-reexec
systemctl enable --now prometheus

# ============ 3. Install Grafana ============
apt-get install -y software-properties-common
add-apt-repository -y "deb https://packages.grafana.com/oss/deb stable main"
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
apt update
apt install grafana -y
systemctl enable --now grafana-server

# ============ 4. Install Alertmanager ============
cd /tmp
curl -LO https://github.com/prometheus/alertmanager/releases/download/v0.27.0/alertmanager-0.27.0.linux-amd64.tar.gz
tar -xvf alertmanager-0.27.0.linux-amd64.tar.gz
cd alertmanager-0.27.0.linux-amd64

cp alertmanager amtool /usr/local/bin/
mkdir /etc/alertmanager /var/lib/alertmanager
cp alertmanager.yml /etc/alertmanager/
chown -R prometheus:prometheus /etc/alertmanager /var/lib/alertmanager

cat <<EOF >/etc/systemd/system/alertmanager.service
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

systemctl daemon-reexec
systemctl enable --now alertmanager

# ============ 5. Configure Prometheus Alerts ============
cat <<EOF >/etc/prometheus/alert.rules.yml
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
cat <<EOF >/etc/alertmanager/alertmanager.yml
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

systemctl restart alertmanager

# ============ 7. Install Node Exporter ============
useradd --no-create-home --shell /bin/false node_exporter
cd /tmp
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar -xvf node_exporter-1.8.2.linux-amd64.tar.gz
cd node_exporter-1.8.2.linux-amd64
cp node_exporter /usr/local/bin/
chown node_exporter:node_exporter /usr/local/bin/node_exporter

cat <<EOF >/etc/systemd/system/node_exporter.service
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

systemctl daemon-reexec
systemctl enable --now node_exporter

# ============ 8. Add Node Exporter to Prometheus ============
cat <<'EOF' >/etc/prometheus/prometheus.yml
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

