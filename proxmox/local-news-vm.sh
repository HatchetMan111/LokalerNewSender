#!/usr/bin/env bash
# ============================================================================
#  LOCAL NEWS PLATFORM – Proxmox VE VM Installer
#  (Stil: Proxmox VE Community Scripts / tteck)
#
#  Erstellt eine Debian-12-Cloud-Init VM mit Docker Compose und deployt
#  die komplette Local-News-Platform (Web-UI, FastAPI, Celery, Postgres,
#  Redis, FFmpeg-Renderer) mit einem einzigen Befehl.
#
#  Ausführen auf dem Proxmox-Host:
#      bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LokalerNewSender/main/proxmox/local-news-vm.sh)"
#
#  Oder mit eigenen Werten:
#      VMID=9100 CORES=4 RAM=8192 REPO_URL=https://github.com/HatchetMan111/LokalerNewSender.git \
#          bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LokalerNewSender/main/proxmox/local-news-vm.sh)"
# ============================================================================
#  Lizenz: MIT
# ============================================================================

set -o pipefail

# ------------------------- Einstellungen (Override per ENV) ----------------
# Test-Defaults (klein). Für Produktion: CORES=8 RAM=16384 DISK_SIZE=64G
# Alle Werte sind wählbar: interaktiv (Dialoge) oder per ENV-Variable.
INTERACTIVE="${INTERACTIVE:-auto}"   # auto | yes | no
VMID="${VMID:-9100}"
VM_NAME="${VM_NAME:-local-news}"
CORES="${CORES:-2}"              # Test: 2 vCPU | MVP-Produktion: 8
RAM="${RAM:-4096}"               # MB – Test: 4096 | MVP-Produktion: 16384
BRIDGE="${BRIDGE:-vmbr0}"
VLAN="${VLAN:-}"
STORAGE="${STORAGE:-local-lvm}"  # VM-Disk Storage
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
DISK_SIZE="${DISK_SIZE:-32G}"    # Test: 32G | MVP-Produktion: 64G+
DEBIAN_VERSION="${DEBIAN_VERSION:-12.7}"
SSH_USER="${SSH_USER:-newsadmin}"
SSH_PASSWORD="${SSH_PASSWORD:-ChangeMe!2026}"   # bitte ändern oder SSH_KEY setzen
SSH_KEY="${SSH_KEY:-}"                          # optional: Pfad zu Public-Key-Datei
REPO_URL="${REPO_URL:-https://github.com/HatchetMan111/LokalerNewSender.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
START_VM="${START_VM:-yes}"

# ------------------------- Farben & Helpers --------------------------------
RD=$(echo "\033[01;31m")
GN=$(echo "\033[01;32m")
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
CL=$(echo "\033[m")

function header_info {
  clear
  cat <<"EOF"
    _          _   _   _   _                          _
   | |        | | | \ | | | |                        | |
   | |        | | |  \| | | |     _ __   ___  _ __  | |_   _   _
   | |        | | | . ` | | |    | '_ \ / _ \| '_ \ | __| | | | |
   | |____    | | | |\  | | |____| | | | (_) | | | || |_  | |_| |
   |______|   |_| |_| \_| |______|_| |_|\___/|_| |_| \__|  \__, |
                                                            __/ |
   LOCAL NEWS PLATFORM – Single VM Setup                   |___/
EOF
}

function msg_info()  { local msg="$1"; echo -e "${YW}[INFO ]${CL} ${msg}"; }
function msg_ok()    { local msg="$1"; echo -e "${GN}[ OK  ]${CL} ${msg}"; }
function msg_error() { local msg="$1"; echo -e "${RD}[ERROR]${CL} ${msg}"; exit 1; }

header_info

# ------------------------- Checks ------------------------------------------
if command -v pveversion >/dev/null 2>&1; then
  msg_info "Proxmox-Version: $(pveversion)"
else
  msg_error "Dieses Script muss auf einem Proxmox-VE-Host ausgeführt werden."
fi
if [[ $EUID -ne 0 ]]; then
  msg_error "Bitte als root ausführen (oder sudo -i)."
fi
if qm status "$VMID" &>/dev/null; then
  msg_error "VMID $VMID existiert bereits. Anderen Wert setzen: VMID=9101 bash ..."
fi

# Speicherplatz prüfen
if ! pvesm status | awk '{print $1}' | grep -qx "$STORAGE"; then
  msg_error "Storage '$STORAGE' nicht gefunden. Vorhandene Storages:"
  pvesm status | awk 'NR>1 {print "  - " $1}' >&2
fi

# ------------------------- VM-Größe wählen ---------------------------------
# Interaktiv (whiptail-Dialoge, tteck-Stil) oder komplett per ENV:
#   INTERACTIVE=no CORES=4 RAM=8192 DISK_SIZE=64G bash -c "..." 
if [[ "$INTERACTIVE" == "yes" ]] || { [[ "$INTERACTIVE" == "auto" ]] && [[ -t 0 ]] && command -v whiptail >/dev/null 2>&1; }; then
  msg_info "Interaktive Konfiguration – jeder Wert per ENV überschreibbar (INTERACTIVE=no)"

  VMID=$(whiptail --inputbox "VM-ID der neuen VM" 9 56 "$VMID" 3>&1 1>&2 2>&3) || true
  VM_NAME=$(whiptail --inputbox "VM-Name" 9 56 "$VM_NAME" 3>&1 1>&2 2>&3) || true
  CORES=$(whiptail --inputbox "vCPUs (Test: 2 · Produktion: 8)" 9 56 "$CORES" 3>&1 1>&2 2>&3) || true
  RAM=$(whiptail --inputbox "RAM in MB (Test: 4096 · Produktion: 16384)" 9 56 "$RAM" 3>&1 1>&2 2>&3) || true
  DISK_SIZE=$(whiptail --inputbox "Systemdisk (Test: 32G · Produktion: 64G+)" 9 56 "$DISK_SIZE" 3>&1 1>&2 2>&3) || true

  STORAGE=$(whiptail --inputbox "Storage für VM-Disk" 9 56 "$STORAGE" 3>&1 1>&2 2>&3) || true
  BRIDGE=$(whiptail --inputbox "Netzwerk-Bridge (VLAN optional als BRIDGE,tag=…)" 9 56 "$BRIDGE" 3>&1 1>&2 2>&3) || true

  header_info
fi

# Plausibilitäts-Check der gewählten Werte
for var in VMID CORES; do
  if ! [[ "${!var}" =~ ^[0-9]+$ ]]; then
    msg_error "$var muss eine Zahl sein (ist: '${!var}')"
  fi
done
if ! [[ "$RAM" =~ ^[0-9]+$ ]]; then
  msg_error "RAM muss in MB als Zahl angegeben werden (ist: '$RAM')"
fi

echo -e "${BL}---------------- VM-Konfiguration ----------------${CL}"
echo -e "  VMID       : ${GN}${VMID}${CL}"
echo -e "  Name       : ${GN}${VM_NAME}${CL}"
echo -e "  vCPU       : ${GN}${CORES}${CL}"
echo -e "  RAM        : ${GN}$((RAM / 1024)) GB${CL} (${RAM} MB)"
echo -e "  Disk       : ${GN}${DISK_SIZE}${CL}"
echo -e "  Storage    : ${GN}${STORAGE}${CL}   Bridge: ${GN}${BRIDGE}${CL}"
echo -e "  SSH-User   : ${GN}${SSH_USER}${CL}"
echo -e "${BL}---------------------------------------------------${CL}"

# ------------------------- Debian Cloud-Image ------------------------------
IMG_URL="https://cloud.debian.org/images/cloud/bookworm/${DEBIAN_VERSION}/debian-${DEBIAN_VERSION}-generic-amd64.qcow2"
IMG_FILE="/tmp/debian-${DEBIAN_VERSION}-generic-amd64.qcow2"

msg_info "Lade Debian ${DEBIAN_VERSION} Cloud-Image herunter ..."
if wget -q -O "$IMG_FILE" "$IMG_URL"; then
  msg_ok "Image heruntergeladen ($(du -h "$IMG_FILE" | cut -f1))"
else
  msg_error "Download fehlgeschlagen: $IMG_URL"
fi

# ------------------------- VM anlegen --------------------------------------
msg_info "Erstelle VM ${VMID} (${VM_NAME}) – ${CORES} vCPU / ${RAM} MB RAM / ${DISK_SIZE} ..."

qm create "$VMID" \
  --name "$VM_NAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --balloon 0 \
  --net0 "virtio,bridge=${BRIDGE}$( [[ -n $VLAN ]] && echo ",tag=${VLAN}" )" \
  --scsihw virtio-scsi-pci \
  --ostype l26 \
  --agent enabled=1 \
  --onboot 1 \
  --boot order=scsi0 &>/dev/null

qm importdisk "$VMID" "$IMG_FILE" "$STORAGE" &>/dev/null
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,iothread=1,discard=on,ssd=1"
qm resize "$VMID" scsi0 "$DISK_SIZE"

qm set "$VMID" \
  --ide2 "${SNIPPET_STORAGE}:cloudinit" \
  --serial0 socket \
  --vga serial0 \
  --ciuser "$SSH_USER"

if [[ -n "$SSH_KEY" ]]; then
  qm set "$VMID" --sshkeys "$SSH_KEY"
else
  qm set "$VMID" --cipassword "$SSH_PASSWORD"
fi

msg_ok "VM ${VMID} erstellt"

# ------------------------- Cloud-Init User-Data ----------------------------
# In-VM-Installer wird per write_files in die VM geschrieben und via
# cloud-init runcmd beim ersten Boot ausgeführt.
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"

cat > "/tmp/local-news-install-${VMID}.sh" <<INSTALLER_EOF
#!/usr/bin/env bash
# In-VM-Installer für Local News Platform (aufgerufen via cloud-init runcmd)
set -e
exec > /var/log/local-news-install.log 2>&1

REPO_URL="${REPO_URL}"
REPO_BRANCH="${REPO_BRANCH}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"

echo "=== Local News Platform In-VM-Installer ==="
date

# ---- Docker installieren ----
if ! command -v docker >/dev/null 2>&1; then
  echo "[INFO] Installiere Docker ..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

# ---- Repository laden ----
mkdir -p /opt/local-news
if [ -d /opt/local-news/.git ]; then
  echo "[INFO] Repository vorhanden – update ..."
  git -C /opt/local-news pull --ff-only || true
elif [ "\$REPO_URL" != "https://github.com/HatchetMan111/LokalerNewSender.git" ]; then
  echo "[INFO] Klone \$REPO_URL ..."
  git clone -b "\$REPO_BRANCH" "\$REPO_URL" /opt/local-news
else
  echo "[WARN] REPO_URL noch nicht gesetzt – lege Grundstruktur an."
  mkdir -p /opt/local-news
fi

cd /opt/local-news

# ---- .env erzeugen (nur falls nicht vorhanden) ----
if [ ! -f .env ]; then
  if [ -f .env.example ]; then
    cp .env.example .env
  else
    {
      echo "POSTGRES_DB=localnews"
      echo "POSTGRES_USER=localnews"
      echo "POSTGRES_PASSWORD=\$POSTGRES_PASSWORD"
      echo "HTTP_PORT=80"
      echo "LLM_PROVIDER=mock"
      echo "OPENAI_API_KEY="
      echo "TTS_PROVIDER=edge"
      echo "TTS_VOICE=de-DE-KatjaNeural"
      echo "IMPORT_INTERVAL_MINUTES=60"
      echo "TZ=Europe/Berlin"
    } > .env
  fi
  sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=\$POSTGRES_PASSWORD/" .env
fi

# ---- Stack starten ----
echo "[INFO] Starte Docker Compose Stack (erster Build dauert einige Minuten) ..."
docker compose up -d --build

# ---- Status ----
sleep 10
docker compose ps
IP=\$(hostname -I | awk '{print \$1}')
echo "[ OK ] Local News Platform erreichbar unter: http://\${IP}"
date
INSTALLER_EOF

# User-Data YAML bauen: Installer einbetten (eingerückt) + runcmd
cat > "/tmp/local-news-user-${VMID}.yaml" <<YAML_EOF
#cloud-config
package_update: true
packages:
  - curl
  - git
  - qemu-guest-agent
YAML_EOF

cat >> "/tmp/local-news-user-${VMID}.yaml" <<YAML_EOF
write_files:
  - path: /opt/local-news-install.sh
    permissions: '0755'
    content: |
YAML_EOF
sed 's/^/      /' "/tmp/local-news-install-${VMID}.sh" >> "/tmp/local-news-user-${VMID}.yaml"
cat >> "/tmp/local-news-user-${VMID}.yaml" <<YAML_EOF
runcmd:
  - [bash, /opt/local-news-install.sh]
YAML_EOF

cp "/tmp/local-news-user-${VMID}.yaml" "${SNIPPET_DIR}/local-news-user-${VMID}.yaml"
qm set "$VMID" --cicustom "user=${SNIPPET_STORAGE}:snippets/local-news-user-${VMID}.yaml"

msg_ok "Cloud-Init konfiguriert (Installer wird beim ersten Boot ausgeführt)"

# ------------------------- Starten -----------------------------------------
if [[ "$START_VM" == "yes" ]]; then
  msg_info "Starte VM ${VMID} ..."
  qm start "$VMID"
  msg_ok "VM gestartet"
fi

# ------------------------- Abschluss ---------------------------------------
IP_HINT="noch unbekannt (Konsole: qm guest cmd ${VMID} network-get-interfaces)"
echo
echo -e "${BL}=================================================================${CL}"
echo -e "${GN}  LOCAL NEWS PLATFORM – VM ${VMID} bereit!${CL}"
echo
echo -e "  SSH-Login : ${YW}${SSH_USER}@<VM-IP>${CL}"
[[ -z "$SSH_KEY" ]] && echo -e "  Passwort  : ${YW}${SSH_PASSWORD}${CL}  (bitte ändern!)"
echo
echo -e "  Die Installation läuft nach dem ersten Boot automatisch ab:"
echo -e "    Fortschritt : ${YW}qm terminal ${VMID}${CL} oder in der VM:"
echo -e "                  ${YW}tail -f /var/log/local-news-install.log${CL}"
echo
echo -e "  Weboberfläche : ${GN}http://<VM-IP>${CL}  (LOCAL NEWSROOM Dashboard)"
echo -e "  API           : ${GN}http://<VM-IP>/api/health${CL}"
echo -e "  Stack-Ordner  : /opt/local-news (in der VM)"
echo
echo -e "  ${RD}Wichtig:${CL} REPO_URL im Script auf dein GitHub-Repo setzen,"
echo -e "  damit die VM die Plattform automatisch bezieht."
echo -e "${BL}=================================================================${CL}"
