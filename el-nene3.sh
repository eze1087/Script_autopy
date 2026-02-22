#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
#  El NeNe 3.0 – Redireccionamiento de Puertos
#
#  ✅ systemd + screen (como manual)
#  ✅ FIX timeout: Type=oneshot + RemainAfterExit=yes + ExecStop
#  ✅ NO pregunta puertos de PDirect/proxy (se editan en el .py)
#  ✅ BadVPN: 7300 por defecto (editable desde menú)
#  ✅ Descarga assets desde GitHub raw (files/)
#  ✅ Estado guardado: /var/lib/nene3/target.conf
#  ✅ Comandos instalados: pdmenu y automenu
#  ✅ Firewall UFW (permitir puertos)
#  ✅ Autostart enable/disable (arranque al reinicio)
#  ✅ STATUS REAL: detecta screen + puertos LISTEN (netstat/ss)
#  ✅ Vuelve al menú tras cada acción (ENTER)
# ==========================================================

APP_NAME="El NeNe 3.0 – Redireccionamiento de Puertos"

# stdin por pipe => usar teclado real
if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
  exec </dev/tty
fi

# ==== TU REPO ====
GITHUB_USER="eze1087"
GITHUB_REPO="Script_autopy"
GITHUB_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# Assets en repo (/files)
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

CMD1="/usr/local/bin/pdmenu"
CMD2="/usr/local/bin/automenu"

# -------- helpers --------
ts(){ date +"%Y%m%d%H%M%S"; }
die(){ echo "❌ $*"; exit 1; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️  $*"; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

press_enter(){ echo; read -r -p "Presioná ENTER para volver al menú..." _; }

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Ejecutá como root: sudo bash $0"; }

backup_if_exists(){
  local f="$1"
  if [[ -f "$f" ]]; then
    local b="${f}.bak-$(ts)"
    cp -a "$f" "$b"
    echo "🧷 Backup: $f -> $b"
  fi
}

ensure_deps(){
  has_cmd python3 || die "Falta python3: sudo apt-get update && sudo apt-get install -y python3"
  has_cmd systemctl || die "No encuentro systemctl (systemd)."
  has_cmd curl || die "Falta curl: sudo apt-get install -y curl"
  has_cmd screen || die "Falta screen: sudo apt-get update && sudo apt-get install -y screen"
  if ! has_cmd netstat && ! has_cmd ss; then
    warn "No encuentro netstat ni ss. Para ver puertos: sudo apt-get install -y net-tools (o iproute2)."
  fi
}

install_commands(){
  # Siempre disponibles
  cat > "$CMD1" <<EOF
#!/usr/bin/env bash
rm -f /tmp/el-nene3.sh
curl -fsSL "${RAW_BASE}/el-nene3.sh" -o /tmp/el-nene3.sh
chmod +x /tmp/el-nene3.sh
sudo /tmp/el-nene3.sh
EOF
  chmod +x "$CMD1"
  cp -f "$CMD1" "$CMD2"
  chmod +x "$CMD2"
}

# -------- selection --------
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
  [[ "$enable_bad" =~ ^[sS]$ ]] && RUN_BAD=1 || RUN_BAD=0
}

# -------- state --------
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

# -------- downloads --------
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

# -------- copy/install --------
copy_files(){
  echo
  echo "📁 Destino: $DEST"
  mkdir -p "$DEST"  # crea carpeta si no existe

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

# -------- services (screen + no timeout) --------
write_service_pdirect(){
  local svc="$SYSTEMD_DIR/$PD_SVC"
  backup_if_exists "$svc"
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

daemon_reload(){ systemctl daemon-reload >/dev/null 2>&1 || true; }

# start sin bloquear => vuelve siempre
enable_start_noblock(){
  [[ "$RUN_PD" -eq 1 ]] && systemctl enable "$PD_SVC" >/dev/null 2>&1 || true
  [[ "$RUN_PX" -eq 1 ]] && systemctl enable "$PX_SVC" >/dev/null 2>&1 || true
  [[ "${RUN_BAD:-0}" -eq 1 ]] && systemctl enable "$BAD_SVC" >/dev/null 2>&1 || true

  [[ "$RUN_PD" -eq 1 ]] && systemctl start --no-block "$PD_SVC" >/dev/null 2>&1 || true
  [[ "$RUN_PX" -eq 1 ]] && systemctl start --no-block "$PX_SVC" >/dev/null 2>&1 || true
  [[ "${RUN_BAD:-0}" -eq 1 ]] && systemctl start --no-block "$BAD_SVC" >/dev/null 2>&1 || true
}

enable_boot(){
  systemctl enable "$PD_SVC" >/dev/null 2>&1 || true
  systemctl enable "$PX_SVC" >/dev/null 2>&1 || true
  systemctl enable "$BAD_SVC" >/dev/null 2>&1 || true
  ok "Autostart HABILITADO (arranca al reinicio)."
}

disable_boot(){
  systemctl disable "$PD_SVC" >/dev/null 2>&1 || true
  systemctl disable "$PX_SVC" >/dev/null 2>&1 || true
  systemctl disable "$BAD_SVC" >/dev/null 2>&1 || true
  ok "Autostart DESHABILITADO."
}

svc_enabled(){ systemctl is-enabled --quiet "$1" 2>/dev/null && echo "ENABLED" || echo "DISABLED"; }
svc_state(){ systemctl is-active --quiet "$1" && echo "ON" || echo "OFF"; }

badvpn_port_current(){
  local port="$BAD_DEFAULT_PORT"
  if [[ -f "$BAD_ENV" ]]; then
    local v
    v="$(grep -E '^BADVPN_PORT=' "$BAD_ENV" | cut -d= -f2 | tr -d '[:space:]' || true)"
    [[ -n "$v" ]] && port="$v"
  fi
  echo "$port"
}

get_default_host(){
  local f="$1"
  [[ -f "$f" ]] || { echo "-"; return; }
  local v
  v="$(grep -E "^[[:space:]]*DEFAULT_HOST[[:space:]]*=" -m1 "$f" 2>/dev/null | sed -E "s/.*=[[:space:]]*'([^']+)'.*/\1/")"
  [[ -n "$v" ]] && echo "$v" || echo "-"
}

# ---- STATUS REAL (screen + LISTEN) ----
is_screen_running(){
  local name="$1"
  screen -ls 2>/dev/null | grep -qE "[0-9]+\.$name" && echo "RUNNING" || echo "OFF"
}

listen_ports_by_prog(){
  local prog="$1"
  if has_cmd netstat; then
    netstat -tnpl 2>/dev/null \
      | awk -v p="$prog" '$6=="LISTEN" && $7 ~ p {print $4}' \
      | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq | paste -sd, - || echo "-"
  elif has_cmd ss; then
    ss -lntp 2>/dev/null \
      | awk -v p="$prog" '$0 ~ p {print $4}' \
      | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq | paste -sd, - || echo "-"
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
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && echo "OPEN" || echo "CLOSED"
  else
    echo "?"
  fi
}

show_status(){
  echo
  echo "══════════════════════════════════════════"
  echo "🔎 Redireccionamiento activo (El NeNe 3.0)"
  echo "══════════════════════════════════════════"

  if load_state; then
    echo "📌 Target: $TARGET"
    echo "📁 Ruta:   $DEST"
    echo "➡️  Destino (DEFAULT_HOST): $(get_default_host "$DEST/PDirect.py")"
  else
    echo "⚠️  No hay instalación registrada (igual detecto procesos/puertos)."
  fi
  echo

  local pd_run px_run
  pd_run="$(is_screen_running "PDirect")"
  px_run="$(is_screen_running "Proxy")"

  local py_ports bad_ports
  py_ports="$(listen_ports_by_prog "python3")"
  bad_ports="$(listen_ports_by_prog "badvpn-udpgw")"

  echo "PDirect: ${pd_run} | unit: $(svc_enabled "$PD_SVC") | python LISTEN: ${py_ports}"
  echo "proxy:   ${px_run} | unit: $(svc_enabled "$PX_SVC") | python LISTEN: ${py_ports}"

  # BadVPN instalado si hay service o bin o LISTEN
  local bad_inst="NO"
  [[ -f "${SYSTEMD_DIR}/${BAD_SVC}" ]] && bad_inst="SI"
  [[ -x "$BAD_BIN" ]] && bad_inst="SI"
  [[ "$bad_ports" != "-" && -n "$bad_ports" ]] && bad_inst="SI"

  if [[ "$bad_inst" == "SI" ]]; then
    local bp
    bp="$(badvpn_port_current)"
    if [[ ! -f "$BAD_ENV" ]] && [[ "$bad_ports" != "-" ]]; then
      bp="$(echo "$bad_ports" | cut -d, -f1)"
    fi
    echo "BadVPN:  $(svc_state "$BAD_SVC") | $(svc_enabled "$BAD_SVC") | port: ${bp} ($(port_open "$bp")) | badvpn LISTEN: ${bad_ports}"
  else
    echo "BadVPN:  NO INSTALADO (no bin, no service, no LISTEN)"
  fi

  echo
  echo "📌 Comandos: pdmenu / automenu"
  echo
}

# -------- Firewall UFW --------
ensure_ufw(){
  if ! has_cmd ufw; then
    warn "No tenés ufw. Instalando..."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y ufw >/dev/null 2>&1 || die "No pude instalar ufw."
  fi
}

firewall_menu(){
  need_root
  ensure_ufw
  echo
  echo "Firewall (UFW):"
  echo "  1) Permitir SSH (22) + habilitar UFW"
  echo "  2) Permitir puertos LISTEN en 0.0.0.0/::: + habilitar UFW"
  echo "  3) Ver estado UFW"
  echo "  4) Deshabilitar UFW"
  read -r -p "Opción: " f

  case "$f" in
    1)
      ufw allow 22/tcp >/dev/null 2>&1 || true
      ufw --force enable >/dev/null 2>&1 || true
      ok "UFW habilitado y SSH permitido."
      ;;
    2)
      ufw allow 22/tcp >/dev/null 2>&1 || true
      local ports=""
      if has_cmd netstat; then
        ports="$(netstat -tnpl 2>/dev/null | awk '$6=="LISTEN" && ($4 ~ /^0\.0\.0\.0:/ || $4 ~ /^:::/){print $4}' \
          | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq)"
      elif has_cmd ss; then
        ports="$(ss -lnt 2>/dev/null | awk '$4 ~ /^0\.0\.0\.0:/ || $4 ~ /^:::/ {print $4}' \
          | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq)"
      fi
      for p in $ports; do
        ufw allow "${p}/tcp" >/dev/null 2>&1 || true
      done
      ufw --force enable >/dev/null 2>&1 || true
      ok "UFW habilitado. Puertos permitidos: ${ports:-"(ninguno detectado)"}"
      ;;
    3) ufw status verbose || true ;;
    4) ufw disable || true; ok "UFW deshabilitado." ;;
    *) echo "Opción inválida." ;;
  esac
  press_enter
}

# -------- actions --------
do_install(){
  need_root
  ensure_deps
  install_commands

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
  enable_start_noblock
  persist_state

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
  systemctl start --no-block "$PD_SVC" 2>/dev/null || true
  systemctl start --no-block "$PX_SVC" 2>/dev/null || true
  systemctl start --no-block "$BAD_SVC" 2>/dev/null || true
  ok "Servicios iniciados."
  press_enter
}

do_restart_all(){
  need_root
  systemctl restart --no-block "$PD_SVC" 2>/dev/null || true
  systemctl restart --no-block "$PX_SVC" 2>/dev/null || true
  systemctl restart --no-block "$BAD_SVC" 2>/dev/null || true
  ok "Servicios reiniciados."
  press_enter
}

do_logs(){
  need_root
  echo
  echo "Logs (últimas 80 líneas):"
  echo "  1) PDirect"
  echo "  2) proxy"
  echo "  3) BadVPN"
  read -r -p "Opción: " o
  case "$o" in
    1) journalctl -u "$PD_SVC" --no-pager -n 80 || true ;;
    2) journalctl -u "$PX_SVC" --no-pager -n 80 || true ;;
    3) journalctl -u "$BAD_SVC" --no-pager -n 80 || true ;;
    *) echo "Opción inválida." ;;
  esac
  press_enter
}

badvpn_set_port(){
  need_root
  local current; current="$(badvpn_port_current)"
  echo
  read -r -p "Puerto BadVPN actual: ${current}. Nuevo puerto (ENTER = ${BAD_DEFAULT_PORT}): " np
  np="${np:-$BAD_DEFAULT_PORT}"
  mkdir -p /etc/default
  echo "BADVPN_PORT=${np}" > "$BAD_ENV"
  chmod 644 "$BAD_ENV"
  daemon_reload
  systemctl restart --no-block "$BAD_SVC" 2>/dev/null || true
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

menu(){
  need_root
  ensure_deps
  install_commands

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
    echo "[8] 🛡️  Firewall UFW (permitir puertos)"
    echo "[9] ✅ Habilitar autostart al reinicio (systemctl enable)"
    echo "[10] ⛔ Deshabilitar autostart (systemctl disable)"
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
      8) firewall_menu ;;
      9) enable_boot; press_enter ;;
      10) disable_boot; press_enter ;;
      0) exit 0 ;;
      *) echo "Opción inválida." ;;
    esac
  done
}

menu
