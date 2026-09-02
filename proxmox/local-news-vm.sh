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
#  Ohne Nachfragen (Werte per ENV):
#      INTERACTIVE=no VMID=9100 CORES=4 RAM=8192 DISK_SIZE=64G \
#          bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LokalerNewSender/main/proxmox/local-news-vm.sh)"
#
#  Alle Parameter (ENV-Override): VMID, VM_NAME, CORES, RAM, DISK_SIZE,
#  STORAGE, BRIDGE, VLAN, SSH_USER, SSH_PASSWORD, SSH_KEY, REPO_URL,
#  REPO_BRANCH, POSTGRES_PASSWORD, START_VM, INTERACTIVE (auto|yes|no)
# ============================================================================
#  Lizenz: MIT
# ============================================================================

set -o pipefail

# ------------------------- Einstellungen (Override per ENV) ----------------
# Test-Defaults (klein). Für Produktion: CORES=8 RAM=16384 DISK_SIZE=64G
INTERACTIVE="${INTERACTIVE:-auto}"   # auto | yes | no
VMID="${VMID:-9100}"
VM_NAME="${VM_NAME:-local-news}"
CORES="${CORES:-2}"              # Test: 2 vCPU | MVP-Produktion: 8
RAM="${RAM:-4096}"               # MB – Test: 4096 | MVP-Produktion: 16384
BRIDGE="${BRIDGE:-vmbr0}"
VLAN="${VLAN:-}"
STORAGE="${STORAGE:-}"           # leer = automatisch wählen (interaktiv oder first match)
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
DISK_SIZE="${DISK_SIZE:-32G}"    # Test: 32G | MVP-Produktion: 64G+
DEBIAN_VERSION="${DEBIAN_VERSION:-}"  # leer = "latest" (immer verfügbar)
SSH_USER="${SSH_USER:-newsadmin}"
SSH_PASSWORD="${SSH_PASSWORD:-ChangeMe!2026}"   # bitte ändern oder SSH_KEY setzen
SSH_KEY="${SSH_KEY:-}"                          # optional: Pfad zu Public-Key-Datei
REPO_URL="${REPO_URL:-https://github.com/HatchetMan111/LokalerNewSender.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
START_VM="${START_VM:-yes}"
WAIT_IP="${WAIT_IP:-yes}"        # yes = bis zu 5 Min. auf die IP warten

# ------------------------- Farben & Helpers --------------------------------
RD=$(echo "\033[01;31m")
GN=$(echo "\033[01;32m")
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
CL=$(echo "\033[m")

function header_info {
  clear
  echo -e "${BL}"
  echo "  +--------------------------------------------------+"
  echo "  |                                                  |"
  echo "  |      L O C A L   N E W S   P L A T F O R M       |"
  echo "  |            Proxmox VM Installer                  |"
  echo "  |        One VM  ·  One Stack  ·  One UI           |"
  echo "  |                                                  |"
  echo "  +--------------------------------------------------+"
  echo -e "${CL}"
}

function msg_info()  { echo -e "${YW}[ INFO ]${CL} $1"; }
function msg_ok()    { echo -e "${GN}[  OK  ]${CL} $1"; }
function msg_error() { echo -e "${RD}[ FEHL ]${CL} $1"; exit 1; }

IMG_FILE="/tmp/local-news-debian-cloud-amd64.qcow2"
trap 'rm -f "$IMG_FILE"' EXIT

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
  msg_error "VMID $VMID existiert bereits. Anderen Wert setzen: VMID=9101 ..."
fi

# Offline/beschädigte Storages (z.B. ausgefallenes NFS) dürfen das Script
# nicht abbrechen: nur aktive Storages mit images-Inhalt gelten als Kandidaten.
STORAGE_TABLE=$(pvesm status --content images 2>/dev/null || true)
ACTIVE_STORAGES=$(echo "$STORAGE_TABLE" | awk 'NR>1 && $3=="active" {print $1}')
if [[ -z "$ACTIVE_STORAGES" ]]; then
  msg_error "Kein aktiver Storage mit images-Inhalt gefunden. pvesm status prüfen."
fi

storage_ok() {
  echo "$ACTIVE_STORAGES" | grep -qx "$1"
}

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

  # Storage-Auswahl als Menü (nur aktive Storages)
  MENU_ARGS=()
  while read -r s; do
    MENU_ARGS+=("$s" "Storage für die VM-Disk")
  done <<< "$ACTIVE_STORAGES"
  if [[ ${#MENU_ARGS[@]} -gt 0 ]]; then
    [[ -n "$STORAGE" ]] && DEFAULT_STORAGE="$STORAGE" || DEFAULT_STORAGE=$(echo "$ACTIVE_STORAGES" | head -1)
    STORAGE=$(whiptail --menu "Storage wählen" 12 58 6 "${MENU_ARGS[@]}" 3>&1 1>&2 2>&3 3>&- ) || STORAGE="$DEFAULT_STORAGE"
  fi

  BRIDGE=$(whiptail --inputbox "Netzwerk-Bridge (VLAN optional als BRIDGE,tag=…)" 9 56 "$BRIDGE" 3>&1 1>&2 2>&3) || true

  header_info
fi

# Storage automatisch wählen, falls nicht gesetzt
if [[ -z "$STORAGE" ]]; then
  if storage_ok "local-lvm"; then
    STORAGE="local-lvm"
  else
    STORAGE=$(echo "$ACTIVE_STORAGES" | head -1)
  fi
fi

# ------------------------- Plausibilitäts-Checks ---------------------------
for var in VMID CORES; do
  if ! [[ "${!var}" =~ ^[0-9]+$ ]]; then
    msg_error "$var muss eine Zahl sein (ist: '${!var}')"
  fi
done
if ! [[ "$RAM" =~ ^[0-9]+$ ]]; then
  msg_error "RAM muss in MB als Zahl angegeben werden (ist: '$RAM')"
fi
if ! storage_ok "$STORAGE"; then
  msg_error "Storage '$STORAGE' ist nicht aktiv oder hat keinen images-Inhalt.
  Aktive Storages: $(echo "$ACTIVE_STORAGES" | tr '\n' ' ')"
fi

# Reicht der Platz auf dem Storage? (Best-Effort: bei Unsicherheit warnen,
# nicht abbrechen – der Admin weiß am besten, wie viel Platz er hat.)
# Autoritative Quelle: pvesh pro Storage (robust gegen kaputte andere Storages)
NODE=$(hostname -s)
DISK_NUM="${DISK_SIZE%[GgMm]}"
if [[ "$DISK_SIZE" =~ [Mm]$ ]]; then DISK_GB=$((DISK_NUM / 1024)); else DISK_GB="$DISK_NUM"; fi
NEEDED_MB=$(( (DISK_GB + 10) * 1024 ))

AVAIL_MB=$(pvesh get "/nodes/$NODE/storage/$STORAGE/status" --output-format json 2>/dev/null \
  | python3 -c "import json,sys; print(int(json.load(sys.stdin).get('avail', 0) / 1024 / 1024))" 2>/dev/null)
[[ -z "$AVAIL_MB" || "$AVAIL_MB" == "0" ]] && \
  AVAIL_MB=$(echo "$STORAGE_TABLE" | awk -v s="$STORAGE" '$1==s && $6 ~ /^[0-9]+$/ {printf "%d", int($6/1024/1024)}' | head -1)

if [[ -n "$AVAIL_MB" && "$AVAIL_MB" -lt "$NEEDED_MB" ]]; then
  AVAIL_SHOW="$((AVAIL_MB / 1024)) GB"; [[ "$AVAIL_MB" -lt 1024 ]] && AVAIL_SHOW="${AVAIL_MB} MB"
  SPACE_WARN="Storage '${STORAGE}' hat nur ${AVAIL_SHOW} frei, für ${DISK_SIZE} + Docker-Images werden ~$((NEEDED_MB / 1024)) GB empfohlen."
  if [[ "$INTERACTIVE" == "yes" ]] || { [[ "$INTERACTIVE" == "auto" ]] && [[ -t 0 ]] && command -v whiptail >/dev/null 2>&1; }; then
    whiptail --yesno "${SPACE_WARN}\n\nTrotzdem fortfahren?" 12 58 3>&1 1>&2 2>&3 && msg_info "Fortfahren auf eigene Verantwortung" || msg_error "Abgebrochen. Anderen Storage wählen oder Speicher freigeben."
  else
    msg_info "HINWEIS: ${SPACE_WARN}"
  fi
fi

if [[ -n "$SSH_KEY" && ! -f "$SSH_KEY" ]]; then
  msg_error "SSH_KEY-Datei '$SSH_KEY' nicht gefunden."
fi

echo -e "${BL}---------------- VM-Konfiguration ----------------${CL}"
echo -e "  VMID       : ${GN}${VMID}${CL}"
echo -e "  Name       : ${GN}${VM_NAME}${CL}"
echo -e "  vCPU       : ${GN}${CORES}${CL}"
echo -e "  RAM        : ${GN}$((RAM / 1024)) GB${CL} (${RAM} MB)"
echo -e "  Disk       : ${GN}${DISK_SIZE}${CL}"
echo -e "  Storage    : ${GN}${STORAGE}${CL}   Bridge: ${GN}${BRIDGE}${CL}"
if [[ -n "$AVAIL_MB" ]]; then
  AVAIL_SHOW="$((AVAIL_MB / 1024)) GB"; [[ "$AVAIL_MB" -lt 1024 ]] && AVAIL_SHOW="${AVAIL_MB} MB"
  echo -e "  Frei       : ${GN}~${AVAIL_SHOW}${CL} auf ${STORAGE}"
fi
echo -e "  SSH-User   : ${GN}${SSH_USER}${CL}"
echo -e "${BL}---------------------------------------------------${CL}"

# ------------------------- Debian Cloud-Image ------------------------------
# cloud.debian.org löscht alte Versionen – "latest" ist der stabile Link.
# Bei Fehlschlag wird automatisch eine fixe Version versucht.
if [[ -n "$DEBIAN_VERSION" ]]; then
  IMG_URLS=(
    "https://cloud.debian.org/images/cloud/bookworm/${DEBIAN_VERSION}/debian-${DEBIAN_VERSION}-generic-amd64.qcow2"
    "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
  )
else
  IMG_URLS=(
    "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
    "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
  )
fi

# Bereits vorhanden und plausibel groß? Dann Download überspringen.
if [[ -f "$IMG_FILE" && $(stat -c%s "$IMG_FILE" 2>/dev/null || echo 0) -gt 200000000 ]]; then
  msg_ok "Cloud-Image bereits vorhanden ($(du -h "$IMG_FILE" | cut -f1)) – Download übersprungen"
else
  msg_info "Lade Debian Cloud-Image herunter ..."
  rm -f "$IMG_FILE"
  DOWNLOADED=""
  for url in "${IMG_URLS[@]}"; do
    msg_info "  Versuche: $url"
    if wget -q --show-progress -O "$IMG_FILE" "$url"; then
      SIZE=$(stat -c%s "$IMG_FILE" 2>/dev/null || echo 0)
      if [[ "$SIZE" -gt 200000000 ]]; then
        DOWNLOADED="$url"
        break
      fi
      msg_info "  Datei zu klein (${SIZE} Bytes) – nächster Versuch"
      rm -f "$IMG_FILE"
    fi
  done
  [[ -z "$DOWNLOADED" ]] && msg_error "Image-Download fehlgeschlagen. Internetverbindung des Hosts prüfen."
  msg_ok "Image heruntergeladen ($(du -h "$IMG_FILE" | cut -f1)) von ${DOWNLOADED##*/}"
fi

# Guest-Agent direkt ins Image stampfen, damit die IP-Ermittlung beim
# ersten Boot sofort funktioniert (falls libguestfs installiert ist).
if command -v virt-customize >/dev/null 2>&1; then
  msg_info "Installiere QEMU Guest Agent ins Image (virt-customize) ..."
  if virt-customize -a "$IMG_FILE" --install qemu-guest-agent --run-command 'systemctl enable qemu-guest-agent' >/dev/null 2>&1; then
    msg_ok "Guest-Agent ins Image installiert"
  else
    msg_info "virt-customize fehlgeschlagen – Agent kommt per Cloud-Init nach dem Boot"
  fi
fi

# ------------------------- VM anlegen --------------------------------------
msg_info "Erstelle VM ${VMID} (${VM_NAME}) – ${CORES} vCPU / ${RAM} MB RAM / ${DISK_SIZE} ..."

NET0="virtio,bridge=${BRIDGE}"
[[ -n "$VLAN" ]] && NET0="${NET0},tag=${VLAN}"

if ! qm create "$VMID" \
  --name "$VM_NAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --balloon 0 \
  --net0 "$NET0" \
  --scsihw virtio-scsi-single \
  --ostype l26 \
  --agent enabled=1 \
  --onboot 1 \
  --boot order=scsi0; then
  qm destroy "$VMID" --purge 2>/dev/null
  msg_error "VM konnte nicht erstellt werden (siehe Fehlermeldung oben)."
fi

if qm importdisk "$VMID" "$IMG_FILE" "$STORAGE" > /tmp/local-news-importdisk.log 2>&1; then
  msg_ok "VM-Disk importiert"
else
  cat /tmp/local-news-importdisk.log >&2
  qm destroy "$VMID" --purge 2>/dev/null
  msg_error "Disk-Import fehlgeschlagen (Log: /tmp/local-news-importdisk.log)."
fi

if ! qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,iothread=1,discard=on,ssd=1"; then
  qm destroy "$VMID" --purge 2>/dev/null
  msg_error "Konnte VM-Disk nicht anhängen."
fi

if ! qm resize "$VMID" scsi0 "$DISK_SIZE"; then
  msg_error "Konnte Disk nicht auf ${DISK_SIZE} vergrößern."
fi

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
elif [ "\$REPO_URL" != "https://github.com/HatchetMan111/LokalerNewSender.git" ] || git ls-remote "\$REPO_URL" >/dev/null 2>&1; then
  echo "[INFO] Klone \$REPO_URL ..."
  git clone -b "\$REPO_BRANCH" "\$REPO_URL" /opt/local-news
else
  echo "[WARN] Repository nicht erreichbar – lege Grundstruktur an."
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
  if qm start "$VMID"; then
    msg_ok "VM gestartet"
  else
    msg_error "VM konnte nicht gestartet werden (qm start ${VMID} für Details)."
  fi
fi

# ------------------------- IP ermitteln ------------------------------------
# qemu-guest-agent wird erst beim ersten Boot per Cloud-Init installiert –
# das kann mehrere Minuten dauern. Wir warten bis zu 5 Minuten und haben
# einen ARP/MAC-Fallback. Abschaltbar mit WAIT_IP=no.
VM_IP=""

function get_ip_by_agent {
  qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | python3 -c "
import json, sys
try:
    for iface in json.load(sys.stdin):
        for addr in iface.get('ip-addresses', []):
            ip = addr.get('ip-address', '')
            if addr.get('ip-address-type') == 'ipv4' and not ip.startswith('127.'):
                print(ip)
except Exception:
    pass
" | head -1
}

function get_ip_by_arp {
  # VM-MAC aus Config holen und im ARP-Cache des Hosts suchen
  local mac
  mac=$(qm config "$VMID" 2>/dev/null | grep '^net0:' | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1)
  [[ -z "$mac" ]] && return
  ip neigh show 2>/dev/null | awk -v m="$(echo "$mac" | tr 'A-F' 'a-f')" 'tolower($5)==m {print $1}' | head -1
}

if [[ "$START_VM" == "yes" && "$WAIT_IP" == "yes" ]]; then
  msg_info "Warte auf VM-IP – jederzeit mit ENTER überspringen ..."
  for i in $(seq 1 36); do
    VM_IP=$(get_ip_by_agent)
    [[ -z "$VM_IP" ]] && VM_IP=$(get_ip_by_arp)
    if [[ -n "$VM_IP" ]]; then
      msg_ok "VM-IP: $VM_IP"
      break
    fi
    if read -t 5 -n 1 -s key 2>/dev/null; then
      msg_info "Warteschleife übersprungen."
      break
    fi
    if [[ $((i % 6)) -eq 0 ]]; then
      VM_STATE=$(qm status "$VMID" 2>/dev/null | awk '/status:/ {print $2}')
      AGENT_STATE="nein"; qm guest cmd "$VMID" ping >/dev/null 2>&1 && AGENT_STATE="ja"
      msg_info "  ... $((i * 5))s – VM: ${VM_STATE:-?} · Guest-Agent: ${AGENT_STATE} · ARP: -"
    fi
  done
  if [[ -z "$VM_IP" ]]; then
    msg_info "IP automatisch nicht ermittelbar. Nachsehen mit:"
    msg_info "  qm guest cmd ${VMID} network-get-interfaces   (braucht fertig gebootete VM)"
    msg_info "  oder: ip neigh | grep <MAC>   (MAC: qm config ${VMID} | grep net0)"
    msg_info "Hinweis: Der erste Boot (Cloud-Init + Docker-Build) dauert auf kleinen"
    msg_info "Hosts gerne 5–15 Minuten – die Weboberfläche erscheint etwas später."
  fi
fi

# ------------------------- Abschluss ---------------------------------------
IP_SHOW="${VM_IP:-<VM-IP>}"
echo
echo -e "${BL}=================================================================${CL}"
echo -e "${GN}  LOCAL NEWS PLATFORM – VM ${VMID} bereit!${CL}"
echo
echo -e "  SSH-Login : ${YW}${SSH_USER}@${IP_SHOW}${CL}"
[[ -z "$SSH_KEY" ]] && echo -e "  Passwort  : ${YW}${SSH_PASSWORD}${CL}  (bitte ändern!)"
echo
echo -e "  Die Installation läuft nach dem ersten Boot automatisch ab"
echo -e "  (Docker-Build dauert einige Minuten):"
echo -e "    Fortschritt : ${YW}qm terminal ${VMID}${CL} oder in der VM:"
echo -e "                  ${YW}tail -f /var/log/local-news-install.log${CL}"
echo
if [[ "$START_VM" == "yes" ]]; then
  echo -e "  Weboberfläche : ${GN}http://${IP_SHOW}${CL}  (LOCAL NEWSROOM Dashboard)"
  echo -e "  API           : ${GN}http://${IP_SHOW}/api/health${CL}"
else
  echo -e "  Weboberfläche : ${GN}http://<VM-IP>${CL}  (VM starten: qm start ${VMID})"
fi
echo -e "  Stack-Ordner  : /opt/local-news (in der VM)"
echo -e "${BL}=================================================================${CL}"
