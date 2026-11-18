#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
BASE_DIR="$TARGET_HOME/local-ai"
VENV_DIR="$BASE_DIR/venv"
OPENWEBUI_DATA="$TARGET_HOME/.open-webui"
MODELFILE_PATH="$BASE_DIR/Modelfile.gemma4"
CUSTOM_MODEL="gemma4-assistant"
LAN_SUBNET="192.168.1.0/24"   # Change to 192.168.0.0/24 if your router uses .0.x

if [[ $EUID -ne 0 ]]; then
  echo "Please run this script with sudo: sudo bash $0"
  exit 1
fi

echo -e "\n=== 1. Installing Base Dependencies & Python 3.12 ==="
apt-get update -y
apt-get install -y curl ca-certificates software-properties-common

if ! command -v python3.12 &>/dev/null; then
  add-apt-repository -y ppa:deadsnakes/ppa
  apt-get update -y
fi
apt-get install -y python3.12 python3.12-venv python3.12-dev

echo -e "\n=== 2. Installing Ollama & Configuring systemd Environment ==="
curl -fsSL https://ollama.com/install.sh | sh

mkdir -p /etc/systemd/system/ollama.service.d
cat <<EOF > /etc/systemd/system/ollama.service.d/override.conf
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
EOF

systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama

echo -e "\n=== 3. Configuring UFW Firewall (If Enabled) ==="
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow from "$LAN_SUBNET" to any port 11434 proto tcp
  ufw allow from "$LAN_SUBNET" to any port 8080 proto tcp
fi

echo -e "\n=== 4. Creating Dedicated Python 3.12 Venv & Installing Open WebUI ==="
sudo -u "$TARGET_USER" mkdir -p "$BASE_DIR" "$OPENWEBUI_DATA"
sudo -u "$TARGET_USER" python3.12 -m venv "$VENV_DIR"
sudo -u "$TARGET_USER" "$VENV_DIR/bin/pip" install --upgrade pip
sudo -u "$TARGET_USER" "$VENV_DIR/bin/pip" install open-webui

echo -e "\n=== 5. Pulling Gemma 4 & Building Custom 65536-Context Model ==="
for i in {1..20}; do
  if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

ollama pull gemma4:e4b

cat <<'EOF' > "$MODELFILE_PATH"
FROM gemma4:e4b

PARAMETER num_ctx 65536
PARAMETER temperature 1.0
PARAMETER top_p 0.95
PARAMETER top_k 64

SYSTEM """
You are an AI Personal Assistant.
You are running on a Windows 11 PC with an NVIDIA RTX 5060 Ti.
You are owned by Josh Moulder.
You do not have access to the internet.
Do not invent facts, URLs, or APIs. If you do not know a factual answer, respond with "I don't know."
"""
EOF
chown "$TARGET_USER:$TARGET_USER" "$MODELFILE_PATH"

ollama create "$CUSTOM_MODEL" -f "$MODELFILE_PATH"

echo -e "\n=== 6. Registering Open WebUI systemd Service ==="
cat <<EOF > /etc/systemd/system/open-webui.service
[Unit]
Description=Open WebUI
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_USER
WorkingDirectory=$BASE_DIR
Environment="DATA_DIR=$OPENWEBUI_DATA"
Environment="OLLAMA_BASE_URL=http://127.0.0.1:11434"
ExecStart=$VENV_DIR/bin/open-webui serve --host 0.0.0.0 --port 8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now open-webui

echo -e "\nSetup Complete!"
echo "Open http://localhost:8080 in your browser and select '$CUSTOM_MODEL'."