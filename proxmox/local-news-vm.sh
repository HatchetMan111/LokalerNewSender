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
GITHUB_TOKEN="${GITHUB_TOKEN:-}"   # optional: Token für PRIVATE Repos (read-only empfohlen)
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
START_VM="${START_VM:-yes}"
WAIT_IP="${WAIT_IP:-yes}"        # yes = bis zu 3 Min. auf die IP warten
STATIC_IP="${STATIC_IP:-}"       # z.B. 192.168.178.220 – leer = DHCP (Fritzbox)
GATEWAY="${GATEWAY:-}"           # leer = Default-Gateway des Hosts
DEBUG="${DEBUG:-no}"             # yes = rohe Guest-Agent-Ausgaben anzeigen

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
  if [[ "$INTERACTIVE" == "yes" ]] || { [[ "$INTERACTIVE" == "auto" ]] && [[ -t 0 ]] && command -v whiptail >/dev/null 2>&1; }; then
    if whiptail --yesno "VMID ${VMID} existiert bereits.\n\nLöschen und neu erstellen? (Cloud-Init läuft nur beim ersten Boot)" 10 58 3>&1 1>&2 2>&3; then
      msg_info "Lösche bestehende VM ${VMID} ..."
      qm stop "$VMID" --timeout 30 2>/dev/null; qm destroy "$VMID" --purge
      msg_ok "VM ${VMID} gelöscht"
    else
      msg_error "Abgebrochen. Wähle eine andere VMID oder lösche VM ${VMID} manuell."
    fi
  else
    msg_error "VMID $VMID existiert bereits. Anderen Wert setzen: VMID=9101 ... (oder: qm destroy $VMID --purge)"
  fi
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

  # Statische IP: bei DHCP-Problemen (z.B. Fritzbox vergibt nichts) deterministisch.
  DEFAULT_STATIC="$STATIC_IP"
  [[ -z "$DEFAULT_STATIC" && "$BRIDGE" =~ ^vmbr ]] && DEFAULT_STATIC="$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | awk '{split($4,a,"/"); split(a[1],b,"."); print b[1]"."b[2]"."b[3]".220"}' | head -1)"
  STATIC_IP=$(whiptail --inputbox "Statische IP der VM (empfohlen! leer = DHCP versuchen)\nBeispiel: 192.168.178.220" 10 56 "$DEFAULT_STATIC" 3>&1 1>&2 2>&3) || true

  header_info
fi

# ------------------------- Statische IP (wird nach VM-Create gesetzt) ------
if [[ -n "$STATIC_IP" ]]; then
  if ! [[ "$STATIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    msg_error "STATIC_IP sieht nicht wie eine IPv4 aus: '$STATIC_IP'"
  fi
  [[ -z "$GATEWAY" ]] && GATEWAY=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
  PREFIX=$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | awk '{split($4,a,"/"); print a[2]}' | head -1)
  [[ -z "$PREFIX" ]] && PREFIX=24
  VM_IP="$STATIC_IP"
  msg_ok "Statische IP wird konfiguriert: ${STATIC_IP}/${PREFIX} (Gateway: ${GATEWAY})"
fi

# Storage automatisch wählen, falls nicht gesetzt
if [[ -z "$STORAGE" ]]; then
  if storage_ok "local-lvm"; then
    STORAGE="local-lvm"
  else
    STORAGE=$(echo "$ACTIVE_STORAGES" | head -1)
  fi
fi

# Bei privatem Repo: Token in die Clone-URL einbetten (read-only Token verwenden!)
CLONE_URL="$REPO_URL"
if [[ -n "$GITHUB_TOKEN" ]]; then
  CLONE_URL="${REPO_URL/https:\/\//https:\/\/${GITHUB_TOKEN}@}"
  msg_info "GitHub-Token für privates Repository wird verwendet."
elif [[ "$REPO_URL" =~ ^https://github\.com/ ]]; then
  msg_info "Hinweis: Bei privatem Repo GITHUB_TOKEN=... setzen oder Repo auf public stellen."
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

# Statische IP (Cloud-Init): umgeht DHCP-Probleme komplett
if [[ -n "$STATIC_IP" ]]; then
  if ! qm set "$VMID" --ipconfig0 "ip=${STATIC_IP}/${PREFIX},gw=${GATEWAY}" --nameserver "${GATEWAY}"; then
    msg_error "Konnte statische IP nicht setzen (qm set ${VMID} --ipconfig0 ...)."
  fi
fi

msg_ok "VM ${VMID} erstellt"

# ------------------------- Cloud-Init User-Data ----------------------------
# In-VM-Installer wird per write_files in die VM geschrieben und via
# cloud-init runcmd beim ersten Boot ausgeführt.
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"

cat > "/tmp/local-news-install-${VMID}.sh" <<INSTALLER_EOF
#!/usr/bin/env bash
# In-VM-Installer für Local News Platform (aufgerufen via cloud-init runcmd
# und systemd-Retry bei jedem Boot, bis der Stack läuft)
exec > /var/log/local-news-install.log 2>&1

# Lock: systemd-Unit und cloud-init runcmd könnten parallel laufen
exec 9>/var/lock/local-news-install.lock
flock -n 9 || { log "[INFO] Installer läuft bereits (Lock) – beende."; exit 0; }

REPO_URL="${CLONE_URL}"
REPO_BRANCH="${REPO_BRANCH}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"

function log() { echo "[\$(date '+%H:%M:%S')] \$*"; }

# Wird auch bei jedem Boot erneut gestartet, bis der Stack läuft –
# so erholt sich die Installation selbst von Netz-/Build-Fehlern.
STACK_UP() { docker compose -f /opt/local-news/docker-compose.yml ps 2>/dev/null | grep -q "backend"; }

if STACK_UP; then
  log "[ OK ] Stack läuft bereits – nichts zu tun."
  exit 0
fi

log "=== Local News Platform In-VM-Installer ==="

# ---- Basispakete (Guest-Agent zuerst, damit die IP auf dem Host auftaucht) ----
log "[INFO] Installiere Basispakete (curl, git, qemu-guest-agent) ..."
apt-get update -qq || true
apt-get install -y -qq curl git qemu-guest-agent || true
systemctl enable --now qemu-guest-agent || true

# ---- Docker installieren ----
if ! command -v docker >/dev/null 2>&1; then
  log "[INFO] Installiere Docker ..."
  curl -fsSL https://get.docker.com | sh || { log "[ERROR] Docker-Installation fehlgeschlagen"; exit 1; }
  systemctl enable --now docker
fi

# ---- Repository laden (Tarball vom Host bevorzugt, sonst git/codeload) ----
if [ ! -f /opt/local-news/docker-compose.yml ]; then
  rm -rf /opt/local-news
  if [ -f /opt/local-news-repo.tar.gz ]; then
    log "[INFO] Entpacke vom Host übermittelten Repo-Tarball ..."
    mkdir -p /opt/local-news
    tar xzf /opt/local-news-repo.tar.gz -C /opt/local-news --strip-components=1
  else
    log "[INFO] Klone \$REPO_URL ..."
    if ! git clone -b "\$REPO_BRANCH" "\$REPO_URL" /opt/local-news; then
      log "[WARN] git clone fehlgeschlagen – Fallback: Tarball-Download"
      REPO_PATH=\$(echo "\$REPO_URL" | sed 's|\.git\$||; s|https://[^@]*@github.com/||; s|https://github.com/||')
      if curl -fsSL "https://codeload.github.com/\${REPO_PATH}/tar.gz/refs/heads/\${REPO_BRANCH}" -o /tmp/repo.tar.gz; then
        mkdir -p /opt/local-news
        tar xzf /tmp/repo.tar.gz -C /opt/local-news --strip-components=1
      else
        log "[ERROR] Repository nicht ladbar (clone UND tarball)"; exit 1
      fi
    fi
  fi
  [ -f /opt/local-news/docker-compose.yml ] || { log "[ERROR] docker-compose.yml fehlt im Repo"; exit 1; }
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
      echo "OPENROUTER_API_KEY="
      echo "ANTHROPIC_API_KEY="
      echo "OLLAMA_BASE_URL="
      echo "LLM_BASE_URL="
      echo "LLM_MODEL="
      echo "LLM_API_KEY="
      echo "TTS_PROVIDER=edge"
      echo "TTS_VOICE=de-DE-KatjaNeural"
      echo "TTS_MODEL=tts-1"
      echo "TTS_BASE_URL="
      echo "VIDEO_STYLE=news-dark"
      echo "RENDERER_BACKEND=ffmpeg"
      echo "RENDERER_WEBHOOK_URL="
      echo "IMPORT_INTERVAL_MINUTES=60"
      echo "TZ=Europe/Berlin"
    } > .env
  fi
  sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=\$POSTGRES_PASSWORD/" .env
fi

# ---- Stack starten (mit Wiederholungen) ----
ATTEMPT=0
until [ \$ATTEMPT -ge 3 ]; do
  ATTEMPT=\$((ATTEMPT+1))
  log "[INFO] Docker Compose Build/Start – Versuch \$ATTEMPT von 3 (dauert beim ersten Mal einige Minuten) ..."
  if docker compose up -d --build; then
    break
  fi
  log "[WARN] Versuch \$ATTEMPT fehlgeschlagen – warte 60 s und versuche erneut ..."
  sleep 60
done

# ---- Status + interner Gesundheitstest ----
sleep 15
docker compose ps
for i in \$(seq 1 12); do
  if curl -s -m 3 http://localhost/api/health | grep -q ok; then
    IP=\$(hostname -I | awk '{print \$1}')
    log "[ OK ] Local News Platform läuft: http://\${IP}"
    exit 0
  fi
  log "[INFO] Warte auf Backend ... (\$i/12)"
  sleep 10
done
log "[WARN] Backend antwortet noch nicht – Details: docker compose logs"
log "[INFO] Der systemd-Service versucht es beim nächsten Boot erneut."
exit 1
INSTALLER_EOF


# User-Data YAML: Benutzer + Passwort-Login (cicustom ersetzt das PVE-User-Data,
# daher müssen ciuser/cipassword hier selbst gesetzt werden!) + Installer + runcmd
cat > "/tmp/local-news-user-${VMID}.yaml" <<YAML_EOF
#cloud-config
hostname: ${VM_NAME}
users:
  - default
  - name: ${SSH_USER}
    shell: /bin/bash
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    plain_text_passwd: '${SSH_PASSWORD}'
    lock_passwd: false
ssh_pwauth: true
chpasswd:
  expire: false
write_files:
  - path: /opt/local-news-install.sh
    permissions: '0755'
    content: |
YAML_EOF
sed 's/^/      /' "/tmp/local-news-install-${VMID}.sh" >> "/tmp/local-news-user-${VMID}.yaml"
cat >> "/tmp/local-news-user-${VMID}.yaml" <<YAML_EOF
  - path: /etc/systemd/system/local-news-install.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Local News Platform Installer (Retry bis Stack laeuft)
      After=network-online.target docker.service
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/opt/local-news-install.sh
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, local-news-install.service]
YAML_EOF

cp "/tmp/local-news-user-${VMID}.yaml" "${SNIPPET_DIR}/local-news-user-${VMID}.yaml"
qm set "$VMID" --cicustom "user=${SNIPPET_STORAGE}:snippets/local-news-user-${VMID}.yaml"

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
# das kann mehrere Minuten dauern. Wir warten bis zu 3 Minuten und haben
# einen ARP/MAC-Fallback. Abschaltbar mit WAIT_IP=no.
# Bei statischer IP (STATIC_IP) entfällt das Warten komplett.
VM_IP="${VM_IP:-}"

function get_ip_by_agent {
  if [[ "$DEBUG" == "yes" ]]; then
    qm guest cmd "$VMID" network-get-interfaces 2>&1
  fi
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
  # Ohne Guest-Agent: VM-MAC aus Config, Broadcast-Ping zwingt die VM in den
  # ARP-Cache des Hosts, dann MAC -> IP auflösen (nur IPv4, kein fe80::).
  local mac bcast ip_prefix
  mac=$(qm config "$VMID" 2>/dev/null | grep '^net0:' | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1)
  [[ -z "$mac" ]] && return
  ip_prefix=$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | head -1)
  if [[ "$ip_prefix" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
    bcast="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.255"
    ping -b -c 1 -W 1 "$bcast" >/dev/null 2>&1
  fi
  ip neigh show 2>/dev/null | awk -v m="$(echo "$mac" | tr 'A-F' 'a-f')" \
    '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && tolower($5)==m {print $1}' | head -1
}

VM_MAC=$(qm config "$VMID" 2>/dev/null | grep '^net0:' | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1)

if [[ "$START_VM" == "yes" && "$WAIT_IP" == "yes" && -z "$VM_IP" ]]; then
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
      msg_info "  ... $((i * 5))s – VM: ${VM_STATE:-?} · Agent: ${AGENT_STATE} · MAC: ${VM_MAC:-?}"
    fi
  done
fi

if [[ -z "$VM_IP" && "$START_VM" == "yes" ]]; then
  msg_info "IP nicht automatisch ermittelbar – so findest du sie:"
  [[ -n "$VM_MAC" ]] && msg_info "  Router (z.B. Fritzbox): Gerät mit MAC ${VM_MAC} suchen"
  msg_info "  Host: qm guest cmd ${VMID} network-get-interfaces   (Agent muss laufen)"
  msg_info "  Host: ip neigh | grep -i \"${VM_MAC:-MAC}\""
  msg_info "Hinweis: Erster Boot + Docker-Build dauern auf kleinen Hosts 5–15 Min."
fi

# Bei statischer IP: kurz warten bis die VM per Ping erreichbar ist
if [[ -n "$STATIC_IP" && "$START_VM" == "yes" ]]; then
  msg_info "Warte bis VM unter ${STATIC_IP} per Ping erreichbar ist ..."
  for i in $(seq 1 24); do
    if ping -c 1 -W 1 "$STATIC_IP" >/dev/null 2>&1; then
      msg_ok "VM antwortet auf Ping: ${STATIC_IP}"
      break
    fi
    [[ $((i % 6)) -eq 0 ]] && msg_info "  ... warte noch ($((i * 5)) s) – Boot dauert etwas"
    read -t 5 -n 1 -s key 2>/dev/null && break
  done
  VM_IP="$STATIC_IP"
fi

# ------------------------- Repo in VM einschleusen (qm guest push) ---------
# Der Host lädt den Repo-Tarball von codeload.github.com (funktioniert auch
# bei Repos, bei denen 'git clone' nach Credentials fragt) und schiebt ihn
# per Guest-Agent direkt in die VM. Die VM braucht dann KEINEN Clone mehr.
# Lokales Repo wird bevorzugt, falls vorhanden (z.B. bei manueller Ausführung
# aus einem Checkout: REPO_DIR=/pfad/zum/repo bash proxmox/local-news-vm.sh).
REPO_DIR="${REPO_DIR:-}"
REPO_TARBALL="/tmp/local-news-repo.tar.gz"
rm -f "$REPO_TARBALL"
if [[ -n "$REPO_DIR" && -f "$REPO_DIR/docker-compose.yml" ]]; then
  tar czf "$REPO_TARBALL" -C "$REPO_DIR" --exclude='.git' --exclude='__pycache__' . && \
    msg_info "Repo-Tarball aus ${REPO_DIR} erstellt"
elif [[ -f "$(dirname "$0")/docker-compose.yml" ]]; then
  tar czf "$REPO_TARBALL" -C "$(dirname "$0")" --exclude='.git' --exclude='__pycache__' . && \
    msg_info "Repo-Tarball aus $(dirname "$0") erstellt"
else
  REPO_PATH=$(echo "$CLONE_URL" | sed 's|\.git$||; s|https://[^@]*@github.com/||; s|https://github.com/||')
  if wget -q -O "$REPO_TARBALL" "https://codeload.github.com/${REPO_PATH}/tar.gz/refs/heads/${REPO_BRANCH}"; then
    msg_info "Repo-Tarball von codeload.github.com geladen ($(du -h "$REPO_TARBALL" | cut -f1))"
  else
    msg_info "Tarball-Download fehlgeschlagen – VM lädt das Repo selbst (git clone mit Tarball-Fallback)"
  fi
fi

# Tarball in die VM schieben (braucht laufenden Guest-Agent; wird weiter unten
# nach dem VM-Start erneut versucht, falls der Agent noch nicht bereit war)
function push_repo_to_vm {
  [[ -f "$REPO_TARBALL" ]] || return 1
  qm guest push "$VMID" "$REPO_TARBALL" "/opt" 2>/dev/null
}

function get_install_progress {
  # Letzte Zeile des Installer-Logs via Guest-Agent (falls der läuft)
  qm guest exec "$VMID" -- tail -n 1 /var/log/local-news-install.log 2>/dev/null \
    | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    out = (d.get('out-data') or '').strip().splitlines()
    if out: print(out[-1][:120])
except Exception:
    pass
" | head -1
}

# ------------------------- Erreichbarkeit prüfen ---------------------------
# Repo-Tarball in die VM schieben (falls Agent inzwischen bereit ist) und
# Installer (neu) anstoßen.
if [[ "$START_VM" == "yes" ]]; then
  if push_repo_to_vm; then
    msg_ok "Repo-Tarball in VM übertragen (/opt/local-news-repo.tar.gz)"
    qm guest exec "$VMID" -- systemctl restart local-news-install >/dev/null 2>&1 \
      && msg_ok "Installer in VM (neu) gestartet"
  fi
fi
# Nicht behaupten, sondern testen: Warten bis /api/health vom Stack antwortet
# (Docker-Build kann auf kleinen Hosts 15-20 Min dauern). ENTER überspringt.
if [[ "$START_VM" == "yes" && -n "$VM_IP" ]]; then
  msg_info "Prüfe Weboberfläche unter http://${VM_IP} – auf kleinen Hosts dauert der Build 15–20 Minuten"
  WEB_OK=""
  PUSHED="no"
  push_repo_to_vm && PUSHED="yes"
  for i in $(seq 1 240); do
    if curl -s -m 3 "http://${VM_IP}/api/health" 2>/dev/null | grep -q '"ok"'; then
      WEB_OK="yes"
      msg_ok "Weboberfläche ist ERREICHBAR: http://${VM_IP}"
      break
    fi
    # Agent kam evtl. erst später hoch -> Tarball jetzt nachschieben
    if [[ "$PUSHED" == "no" ]] && [[ $((i % 12)) -eq 1 ]]; then
      if push_repo_to_vm; then
        PUSHED="yes"
        msg_ok "Repo-Tarball nachträglich in VM übertragen – Installer startet"
        qm guest exec "$VMID" -- systemctl restart local-news-install >/dev/null 2>&1 || true
      fi
    fi
    if read -t 5 -n 1 -s key 2>/dev/null; then
      msg_info "Prüfung übersprungen."
      break
    fi
    if [[ $((i % 12)) -eq 0 ]]; then
      PROGRESS=$(get_install_progress)
      [[ -n "$PROGRESS" ]] && msg_info "  ... $((i * 5))s · Installer: ${PROGRESS}" \
                             || msg_info "  ... $((i * 5))s · (kein Installer-Log via Agent erreichbar)"
    fi
  done
  if [[ -z "$WEB_OK" ]]; then
    msg_info "Noch nicht erreichbar – Status prüfen mit:"
    msg_info "  ssh ${SSH_USER}@${VM_IP}   (Passwort: ${SSH_PASSWORD})"
    msg_info "  tail -f /var/log/local-news-install.log"
    msg_info "  sudo docker compose -f /opt/local-news/docker-compose.yml ps"
    msg_info "Der systemd-Service 'local-news-install' wiederholt die Installation automatisch bei Bedarf."
  fi
fi

# ------------------------- Abschluss ---------------------------------------
IP_SHOW="${VM_IP:-<VM-IP>}"
echo
echo -e "${BL}=================================================================${CL}"
echo -e "${GN}  LOCAL NEWS PLATFORM – VM ${VMID}${CL}"
echo
if [[ -n "$VM_IP" && "$WEB_OK" == "yes" ]]; then
  echo -e "  ${GN}✓ Weboberfläche ist online: http://${IP_SHOW}${CL}"
elif [[ -n "$VM_IP" ]]; then
  echo -e "  ${YW}○ Weboberfläche noch nicht erreichbar (Build läuft ggf. noch)${CL}"
fi
echo
echo -e "  ${BL}Zugangsdaten:${CL}"
echo -e "  SSH-Benutzer : ${GN}${SSH_USER}${CL}   (Login: ssh ${SSH_USER}@${IP_SHOW})"
[[ -z "$SSH_KEY" ]] && echo -e "  SSH-Passwort : ${YW}${SSH_PASSWORD}${CL}  (bitte ändern!)"
echo -e "  Konsolen-Login (qm terminal ${VMID}): ${GN}${SSH_USER}${CL} / ${YW}${SSH_PASSWORD}${CL}"
echo
echo -e "  Weboberfläche : ${GN}http://${IP_SHOW}${CL}  (LOCAL NEWSROOM Dashboard)"
echo -e "  API           : ${GN}http://${IP_SHOW}/api/health${CL}"
echo -e "  Stack-Ordner  : /opt/local-news (in der VM)"
echo
if [[ -n "$VM_IP" && "$WEB_OK" != "yes" ]]; then
  echo -e "  ${BL}Status prüfen:${CL}"
  echo -e "    ssh ${SSH_USER}@${IP_SHOW}"
  echo -e "    tail -f /var/log/local-news-install.log"
  echo -e "    sudo docker compose -f /opt/local-news/docker-compose.yml ps"
fi
echo -e "${BL}=================================================================${CL}"
