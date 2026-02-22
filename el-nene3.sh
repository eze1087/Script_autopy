#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
#  El NeNe 3.0 – Script Automatizado de Redireccionamiento
#  PDirect.py + proxy.py + BadVPN UDPGW
#
#  ✅ Modo "manual-compatible": systemd + screen -DmS
#  ✅ FIX systemd: Type=oneshot + RemainAfterExit (sin timeouts)
#  ✅ NO pregunta puertos de PDirect/proxy (se editan en el .py)
#  ✅ BadVPN: 7300 por defecto (editable desde menú)
#  ✅ Descarga assets desde GitHub raw (files/)
#  ✅ Menú muestra ON/OFF + ENABLED/DISABLED + puertos OPEN/CLOSED (netstat/ss)
#  ✅ Siempre guarda estado: /var/lib/nene3/target.conf
#
#  Repo esperado:
#   el-nene3.sh
#   files/PDirect.py
#   files/proxy.py
#   files/badvpn-udpgw
#   files/antcrashvpn.sh
# ==========================================================

APP_NAME="El NeNe 3.0 – Redireccionamiento de Puertos"

# Si se ejecuta por pipe (curl | bash) stdin puede no ser TTY.
# Forzamos lectura del teclado si existe /dev/tty.
if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
  exec </dev/tty
fi

# ==== TU REPO ====
GITHUB_USER="eze1087"
GITHUB_REPO="Script_autopy"
GITHUB_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# Assets en repo (dentro de /files)
PD_FILE="PDirect.py"
PX_FILE="proxy.py"
BAD_FILE="badvpn-udpgw"
WR_FILE="antcrashvpn.sh"

DL_DIR="/tmp/nene3-files"

SYSTEMD_DIR="/etc/systemd/system"

PD_SVC="pdirect.service"
PX_SVC="proxy.service"

# BadVPN
BAD_SVC="badvpn-udpgw.service"
BAD_BIN="/bin/badvpn-udpgw"
BAD_WRAPPER="/bin/antcrashvpn.sh"
BAD_ENV="/etc/default/nene3-badvpn"
BAD_DEFAULT_PORT="7300"

STATE_DIR="/var/lib/nene3"
STATE_FILE="${STATE_DIR}/target.conf"
GLOBAL_CMD="/usr/local/bin/nene3"

# ------------ helpers ------------
ts(){ date +"%Y%m%d%H%M%S"; }
die(){ echo "❌ $*"; exit 1; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️  $*"; }

press_enter(){
  echo
  read -r -p "Presioná ENTER para volver al menú..." _
}

need_root(){
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Ejecutá como root: sudo bash $0"
  fi
}

backup_if_exists(){
  local f="$1"
  if [[ -f "$f" ]]; then
    local b="${f}.bak-$(ts)"
    cp -a "$f" "$b"
    echo "🧷 Backup: $f -> $b"
  fi
}

has_cmd(){ command -v "$1" >/dev/null 2>&1; }

ensure_deps(){
  has_cmd python3 || die "Falta python3: sudo apt-get update && sudo apt-get install -y python3"
  has_cmd systemctl || die "No encuentro systemctl (systemd)."
  has_cmd curl || die "Falta curl: sudo apt-get install -y curl"
  has_cmd screen || die "Falta screen: sudo apt-get update && sudo apt-get install -y screen"
  # netstat suele venir de net-tools; si no está, usamos ss
  if ! has_cmd netstat && ! has_cmd ss; then
    warn "No encuentro netstat ni ss. Para ver puertos OPEN/CLOSED instalá: sudo apt-get install -y net-tools (o iproute2)."
  fi
}

# ------------ target selection ------------
pick_target(){
  echo "==============================================="
  echo " $APP_NAME"
  echo "==============================================="
  echo "¿Qué sistema tenés instalado?"
  echo "  1) VPS-MX   -> /etc/VPS-MX/protocolos"
  echo "  2) SSHPLUS  -> /etc/SSHPlus"
  echo "  3) VPS-AGN  -> /etc/VPS-AGN/protocolos"
  echo "  4) ADMRufu  -> /etc/ADMRufu"
  echo "  5) LATAM    -> /etc/LATAM/protocolos"
  echo
  read -r -p "Opción (1-5): " opt
  case "$opt" in
    1) TARGET="VPS-MX";  DEST="/etc/VPS-MX/protocolos" ;;
    2) TARGET="SSHPLUS"; DEST="/etc/SSHPlus" ;;
    3) TARGET="VPS-AGN"; DEST="/etc/VPS-AGN/protocolos" ;;
    4) TARGET="ADMRufu"; DEST="/etc/ADMRufu" ;;
    5) TARGET="LATAM";   DEST="/etc/LATAM/protocolos" ;;
    *) die "Opción inválida." ;;
  esac
}

ask_components(){
  echo
  echo "¿Qué querés instalar/activar?"
  echo "  1) Solo PDirect"
  echo "  2) Solo proxy"
  echo "  3) PDirect + proxy"
  read -r -p "Opción (1-3): " w
  case "$w" in
    1) RUN_PD=1; RUN_PX=0 ;;
    2) RUN_PD=0; RUN_PX=1 ;;
    3) RUN_PD=1; RUN_PX=1 ;;
    *) die "Opción inválida." ;;
  esac

  echo
  read -r -p "¿Habilitar BadVPN UDPGW? (s/n) [s]: " enable_bad
  enable_bad="${enable_bad:-s}"
  if [[ "$enable_bad" =~ ^[sS]$ ]]; then
    RUN_BAD=1
  else
    RUN_BAD=0
  fi
}

# ------------ state ------------
persist_state(){
  mkdir -p "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
TARGET=${TARGET}
DEST=${DEST}
RUN_PD=${RUN_PD}
RUN_PX=${RUN_PX}
RUN_BAD=${RUN_BAD}
EOF
}

load_state(){
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    return 0
  fi
  return 1
}

# ------------ downloads ------------
download_asset(){
  local name="$1"
  local url="${RAW_BASE}/files/${name}"
  local out="${DL_DIR}/${name}"
  mkdir -p "$DL_DIR"
  echo "⬇️  Descargando ${name}..." >&2
  curl -fsSL "$url" -o "$out" || die "No pude descargar: $url"
  echo "$out"
}

ensure_assets(){
  PD_SRC="$(download_asset "$PD_FILE")"
  PX_SRC="$(download_asset "$PX_FILE")"
  if [[ "${RUN_BAD:-0}" -eq 1 ]]; then
    BAD_SRC="$(download_asset "$BAD_FILE")"
    WR_SRC="$(download_asset "$WR_FILE")"
  fi
}

# ------------ install/copy ------------
copy_files(){
  echo
  echo "📁 Destino: $DEST"
  mkdir -p "$DEST"

  backup_if_exists "$DEST/PDirect.py"
  backup_if_exists "$DEST/proxy.py"

  cp -f "$PD_SRC" "$DEST/PDirect.py"
  cp -f "$PX_SRC" "$DEST/proxy.py"
  chmod 755 "$DEST/PDirect.py" "$DEST/proxy.py"
  ok "Copiados PDirect.py y proxy.py en $DEST"

  if [[ "${RUN_BAD:-0}" -eq 1 ]]; then
    backup_if_exists "$BAD_BIN"
    backup_if_exists "$BAD_WRAPPER"

    cp -f "$BAD_SRC" "$BAD_BIN"
    cp -f "$WR_SRC"  "$BAD_WRAPPER"
    chmod 755 "$BAD_BIN" "$BAD_WRAPPER"
    ok "BadVPN bin+wrapper instalados en /bin"
  fi
}

# ------------ services (FIXED) ------------
write_service_pdirect(){
  local svc="$SYSTEMD_DIR/$PD_SVC"
  backup_if_exists "$svc"

  # FIX: oneshot + RemainAfterExit para screen (sin timeouts)
  cat > "$svc" <<EOF
[Unit]
Description=El NeNe 3.0 - PDirect (${TARGET}) via screen
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${DEST}
ExecStart=/usr/bin/screen -DmS PDirect /usr/bin/python3 ${DEST}/PDirect.py
ExecStop=/usr/bin/screen -S PDirect -X quit
User=root

[Install]
WantedBy=multi-user.target
EOF
  ok "Servicio creado: $PD_SVC"
}

write_service_proxy(){
  local svc="$SYSTEMD_DIR/$PX_SVC"
  backup_if_exists "$svc"

  cat > "$svc" <<EOF
[Unit]
Description=El NeNe 3.0 - proxy (${TARGET}) via screen
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${DEST}
ExecStart=/usr/bin/screen -DmS Proxy /usr/bin/python3 ${DEST}/proxy.py
ExecStop=/usr/bin/screen -S Proxy -X quit
User=root

[Install]
WantedBy=multi-user.target
EOF
  ok "Servicio creado: $PX_SVC"
}

write_badvpn_env_default(){
  mkdir -p /etc/default
  if [[ -f "$BAD_ENV" ]]; then
    ok "BadVPN env ya existe: $BAD_ENV (lo respeto)"
    return
  fi
  echo "BADVPN_PORT=${BAD_DEFAULT_PORT}" > "$BAD_ENV"
  chmod 644 "$BAD_ENV"
  ok "BadVPN env creado (puerto=${BAD_DEFAULT_PORT})"
}

write_service_badvpn(){
  local svc="$SYSTEMD_DIR/$BAD_SVC"
  backup_if_exists "$svc"

  cat > "$svc" <<EOF
[Unit]
Description=El NeNe 3.0 - BadVPN UDPGW
After=network.target

[Service]
Type=simple
EnvironmentFile=-${BAD_ENV}
ExecStart=${BAD_WRAPPER} \${BADVPN_PORT:-${BAD_DEFAULT_PORT}}
User=root
Restart=on-failure
RestartSec=2
LimitNOFILE=999999

[Install]
WantedBy=multi-user.target
EOF
  ok "Servicio creado: $BAD_SVC"
}

daemon_reload(){
  systemctl daemon-reload >/dev/null 2>&1 || true
}

enable_start(){
  # Silenciar output (symlinks) para que no parezca que “se quedó”
  [[ "$RUN_PD" -eq 1 ]] && systemctl enable --now "$PD_SVC" >/dev/null 2>&1 || true
  [[ "$RUN_PX" -eq 1 ]] && systemctl enable --now "$PX_SVC" >/dev/null 2>&1 || true
  [[ "${RUN_BAD:-0}" -eq 1 ]] && systemctl enable --now "$BAD_SVC" >/dev/null 2>&1 || true
}

svc_state(){ systemctl is-active --quiet "$1" && echo "ON" || echo "OFF"; }
svc_enabled(){ systemctl is-enabled --quiet "$1" 2>/dev/null && echo "ENABLED" || echo "DISABLED"; }

badvpn_port_current(){
  local port="$BAD_DEFAULT_PORT"
  if [[ -f "$BAD_ENV" ]]; then
    local v
    v="$(grep -E '^BADVPN_PORT=' "$BAD_ENV" | cut -d= -f2 | tr -d '[:space:]' || true)"
    [[ -n "$v" ]] && port="$v"
  fi
  echo "$port"
}

screen_pid(){
  local name="$1"
  screen -ls 2>/dev/null | awk -v n="$name" '$0 ~ n {print $1}' | head -n1 | cut -d. -f1
}

get_default_host(){
  local f="$1"
  [[ -f "$f" ]] || { echo "-"; return; }
  local v
  v="$(grep -E "^[[:space:]]*DEFAULT_HOST[[:space:]]*=" -m1 "$f" 2>/dev/null | sed -E "s/.*=[[:space:]]*'([^']+)'.*/\1/")"
  [[ -n "$v" ]] && echo "$v" || echo "-"
}

# Detecta puertos reales escuchando para un programa/pid (usa netstat si existe, sino ss)
ports_by_pid(){
  local pid="$1"
  [[ -n "$pid" ]] || { echo "-"; return; }

  if has_cmd netstat; then
    netstat -tnpl 2>/dev/null | awk -v p="$pid" '$0 ~ (p"/") && $6=="LISTEN" {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq | paste -sd, - || true
  elif has_cmd ss; then
    ss -lntp 2>/dev/null | awk -v p="$pid" '$0 ~ ("pid="p",") {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq | paste -sd, - || true
  else
    echo "-"
  fi
}

port_open(){
  local port="$1"
  [[ -n "$port" ]] || { echo "?"; return; }
  if has_cmd netstat; then
    netstat -tnpl 2>/dev/null | awk '{print $4,$6}' | grep -qE "[:.]${port}[[:space:]]+LISTEN$" && echo "OPEN" || echo "CLOSED"
  elif has_cmd ss; then
    ss -lntp 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && echo "OPEN" || echo "CLOSED"
  else
    echo "?"
  fi
}

show_status(){
  echo
  echo "══════════════════════════════════════════"
  echo "🔎 Redireccionamiento activo (El NeNe 3.0)"
  echo "══════════════════════════════════════════"

  if ! load_state; then
    warn "Todavía no hay instalación registrada. Usá [1] Instalar/Actualizar"
    return
  fi

  echo "📌 Target: $TARGET"
  echo "📁 Ruta:   $DEST"
  echo "➡️  Destino (DEFAULT_HOST): $(get_default_host "$DEST/PDirect.py")"
  echo

  local pd_pid px_pid
  pd_pid="$(screen_pid "PDirect")"
  px_pid="$(screen_pid "Proxy")"

  # Puertos reales por PID (screen crea proceso; el python suele ser hijo, pero netstat muestra python3 PID real).
  # Igual mostramos: si encontramos python3 escuchando, se ve en netstat.
  local pd_ports px_ports
  pd_ports="$(has_cmd netstat && netstat -tnpl 2>/dev/null | awk '$6=="LISTEN" && $7 ~ /python3/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq | paste -sd, - || echo "-")"
  px_ports="$(has_cmd netstat && netstat -tnpl 2>/dev/null | awk '$6=="LISTEN" && $7 ~ /python3/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq | paste -sd, - || echo "-")"

  # Mejor: si hay python3 escuchando, mostramos todos (en SSHPlus normalmente es 80).
  echo "PDirect: $(svc_state "$PD_SVC") | $(svc_enabled "$PD_SVC") | screenPID: ${pd_pid:-"-"} | puertos python3 LISTEN: ${pd_ports:-"-"}"
  echo "proxy:   $(svc_state "$PX_SVC") | $(svc_enabled "$PX_SVC") | screenPID: ${px_pid:-"-"} | (si proxy escucha, aparecerá en python3 LISTEN)"

  if systemctl list-unit-files 2>/dev/null | grep -q "^${BAD_SVC}"; then
    local bad_port bad_open
    bad_port="$(badvpn_port_current)"
    bad_open="$(port_open "$bad_port")"
    echo "BadVPN:  $(svc_state "$BAD_SVC") | $(svc_enabled "$BAD_SVC") | port: 127.0.0.1:${bad_port} (${bad_open})"
  else
    echo "BadVPN:  NO INSTALADO"
  fi
  echo
}

install_global_cmd(){
  cat > "$GLOBAL_CMD" <<EOF
#!/usr/bin/env bash
# Método compatible: descargar y ejecutar (evita /dev/fd y curl (23))
rm -f /tmp/el-nene3.sh
curl -fsSL "${RAW_BASE}/el-nene3.sh" -o /tmp/el-nene3.sh
chmod +x /tmp/el-nene3.sh
sudo /tmp/el-nene3.sh
EOF
  chmod +x "$GLOBAL_CMD"
  ok "Comando global instalado: nene3"
}

# ------------ actions ------------
do_install(){
  need_root
  ensure_deps
  pick_target
  ask_components

  ensure_assets
  copy_files

  [[ "$RUN_PD" -eq 1 ]] && write_service_pdirect
  [[ "$RUN_PX" -eq 1 ]] && write_service_proxy

  if [[ "${RUN_BAD:-0}" -eq 1 ]]; then
    write_badvpn_env_default
    write_service_badvpn
  fi

  daemon_reload
  enable_start
  persist_state
  install_global_cmd

  ok "Instalación/actualización completada."
  show_status
  press_enter
}

do_stop_all(){
  need_root
  systemctl stop "$PD_SVC" 2>/dev/null || true
  systemctl stop "$PX_SVC" 2>/dev/null || true
  systemctl stop "$BAD_SVC" 2>/dev/null || true
  ok "Servicios detenidos."
  press_enter
}

do_start_all(){
  need_root
  systemctl start "$PD_SVC" 2>/dev/null || true
  systemctl start "$PX_SVC" 2>/dev/null || true
  systemctl start "$BAD_SVC" 2>/dev/null || true
  ok "Servicios iniciados."
  press_enter
}

do_restart_all(){
  need_root
  systemctl restart "$PD_SVC" 2>/dev/null || true
  systemctl restart "$PX_SVC" 2>/dev/null || true
  systemctl restart "$BAD_SVC" 2>/dev/null || true
  ok "Servicios reiniciados."
  press_enter
}

do_logs(){
  need_root
  echo
  echo "Logs:"
  echo "  1) PDirect"
  echo "  2) proxy"
  echo "  3) BadVPN"
  read -r -p "Opción: " o
  case "$o" in
    1) journalctl -u "$PD_SVC" -f ;;
    2) journalctl -u "$PX_SVC" -f ;;
    3) journalctl -u "$BAD_SVC" -f ;;
    *) die "Opción inválida." ;;
  esac
}

badvpn_set_port(){
  need_root
  local current
  current="$(badvpn_port_current)"
  echo
  read -r -p "Puerto BadVPN actual: ${current}. Nuevo puerto (ENTER = ${BAD_DEFAULT_PORT}): " np
  np="${np:-$BAD_DEFAULT_PORT}"
  mkdir -p /etc/default
  echo "BADVPN_PORT=${np}" > "$BAD_ENV"
  chmod 644 "$BAD_ENV"
  daemon_reload
  systemctl restart "$BAD_SVC" 2>/dev/null || true
  ok "BadVPN reiniciado en puerto ${np}."
  press_enter
}

do_uninstall(){
  need_root
  systemctl stop "$PD_SVC" 2>/dev/null || true
  systemctl disable "$PD_SVC" 2>/dev/null || true
  systemctl stop "$PX_SVC" 2>/dev/null || true
  systemctl disable "$PX_SVC" 2>/dev/null || true
  systemctl stop "$BAD_SVC" 2>/dev/null || true
  systemctl disable "$BAD_SVC" 2>/dev/null || true
  rm -f "$SYSTEMD_DIR/$PD_SVC" "$SYSTEMD_DIR/$PX_SVC" "$SYSTEMD_DIR/$BAD_SVC"
  daemon_reload
  ok "Servicios removidos (no borro los .py ni /bin/badvpn-udpgw)."
  press_enter
}

# ------------ menu ------------
menu(){
  need_root
  while true; do
    echo
    echo "╔══════════════════════════════════════════════╗"
    echo "║  🧠  $APP_NAME"
    echo "╚══════════════════════════════════════════════╝"

    show_status

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "[1] 🛠️  Instalar / Actualizar (descarga desde GitHub)"
    echo "[2] ⛔  Detener TODO"
    echo "[3] ▶️  Reanudar TODO"
    echo "[4] 🔄 Reiniciar TODO"
    echo "[5] 📜 Ver logs"
    echo "[6] 🧨 Desinstalar servicios"
    echo "[7] 🔧 Cambiar puerto BadVPN (default 7300)"
    echo "[0] Salir"
    echo
    read -r -p "Opción: " op
    case "$op" in
      1) do_install ;;
      2) do_stop_all ;;
      3) do_start_all ;;
      4) do_restart_all ;;
      5) do_logs ;;
      6) do_uninstall ;;
      7) badvpn_set_port ;;
      0) exit 0 ;;
      *) echo "Opción inválida." ;;
    esac
  done
}

menu
