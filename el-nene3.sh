#!/usr/bin/env bash
set -euo pipefail

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

ts(){ date +"%Y%m%d%H%M%S"; }
die(){ echo "❌ $*"; exit 1; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️  $*"; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

press_enter(){ echo; read -r -p "Presioná ENTER para volver al menú..." _; }
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Ejecutá como root: sudo bash $0"; }

# runner: siempre vuelve al menú
run_step(){
  local title="$1"; shift || true
  echo; echo "▶️  $title"
  set +e
  "$@"
  local rc=$?
  set -e
  [[ $rc -ne 0 ]] && warn "La acción terminó con error (rc=$rc)." || ok "Listo."
  press_enter
}

# Backup ÚNICO (para binarios/servicios) => evita miles de backups
backup_once(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  [[ -f "${f}.bak" ]] && return 0
  cp -a "$f" "${f}.bak"
  echo "🧷 Backup único: $f -> ${f}.bak"
}

ensure_deps(){
  has_cmd systemctl || die "No encuentro systemctl (systemd)."
  has_cmd curl || die "Falta curl: sudo apt-get install -y curl"
  has_cmd nano || warn "No tenés nano (para editar). Instalá: sudo apt-get install -y nano"
  if ! has_cmd python3 && ! has_cmd python; then
    die "Falta python/python3. Instalá: sudo apt-get update && sudo apt-get install -y python3"
  fi
  has_cmd screen || warn "No tenés screen (SSHPLUS/VPS-MX/ADMRufu lo usan). Instalá: sudo apt-get install -y screen"
  if ! has_cmd netstat && ! has_cmd ss; then
    warn "No encuentro netstat ni ss. Para ver puertos: sudo apt-get install -y net-tools (o iproute2)."
  fi
}

install_commands(){
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

# ---------------- RUTAS EXACTAS ----------------
pick_target(){
  echo "==============================================="
  echo " $APP_NAME"
  echo "==============================================="
  echo "¿Qué sistema tenés instalado?"
  echo "  1) VPS-MX   -> /etc/VPS-MX/protocolos"
  echo "  2) SSHPLUS  -> /etc/SSHPlus"
  echo "  3) VPS-AGN  -> /etc/VPS-AGN/protocols"
  echo "  4) ADMRufu  -> /etc/ADMRufu/install"
  echo "  5) LATAM    -> /etc/LATAM/protocolos"
  echo
  read -r -p "Opción (1-5): " opt
  case "$opt" in
    1) TARGET="VPS-MX";  DEST="/etc/VPS-MX/protocolos" ;;
    2) TARGET="SSHPLUS"; DEST="/etc/SSHPlus" ;;
    3) TARGET="VPS-AGN"; DEST="/etc/VPS-AGN/protocols" ;;
    4) TARGET="ADMRufu"; DEST="/etc/ADMRufu/install" ;;
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

# ---------------- state ----------------
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

# ---------------- downloads ----------------
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

# ✅ Pisa siempre (sin backups repetidos de .py)
copy_files(){
  echo
  echo "📁 Destino (service path): $DEST"
  mkdir -p "$DEST"
  cp -f "$PD_SRC" "$DEST/PDirect.py"
  cp -f "$PX_SRC" "$DEST/proxy.py"
  chmod 755 "$DEST/PDirect.py" "$DEST/proxy.py"
  ok "Reemplazados PDirect.py y proxy.py en $DEST"

  if [[ "${RUN_BAD:-0}" -eq 1 ]]; then
    backup_once "$BAD_BIN"
    backup_once "$BAD_WRAPPER"
    cp -f "$BAD_SRC" "$BAD_BIN"
    cp -f "$WR_SRC"  "$BAD_WRAPPER"
    chmod 755 "$BAD_BIN" "$BAD_WRAPPER"
    ok "Actualizado BadVPN en /bin"
  fi
}

# --------- Liberar 80/443 ----------
listener_prog_on_port(){
  local port="$1"
  if has_cmd netstat; then
    netstat -tnpl 2>/dev/null | awk -v p=":${port}" '$6=="LISTEN" && $4 ~ p {print $7}' | head -n1
  else
    echo ""
  fi
}

stop_common_web_services(){
  local svc
  for svc in apache2 nginx httpd lighttpd caddy haproxy; do
    systemctl is-active --quiet "$svc" 2>/dev/null && {
      warn "Deteniendo servicio que puede ocupar 80/443: $svc"
      systemctl stop "$svc" 2>/dev/null || true
      systemctl disable "$svc" 2>/dev/null || true
    }
  done
}

free_ports_80_443(){
  need_root
  stop_common_web_services

  local info80 info443
  info80="$(listener_prog_on_port 80 || true)"
  info443="$(listener_prog_on_port 443 || true)"

  if [[ -n "$info80" && "$info80" =~ ^[0-9]+/ ]]; then
    local pid="${info80%%/*}" name="${info80#*/}"
    if [[ "$name" != "python3" && "$name" != "badvpn-udpgw" ]]; then
      warn "Puerto 80 ocupado por: $info80. Terminando PID $pid"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi

  if [[ -n "$info443" && "$info443" =~ ^[0-9]+/ ]]; then
    local pid="${info443%%/*}" name="${info443#*/}"
    if [[ "$name" != "python3" && "$name" != "badvpn-udpgw" ]]; then
      warn "Puerto 443 ocupado por: $info443. Terminando PID $pid"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
}

# ====== SERVICES POR SISTEMA (EXACTOS A LO QUE PEGASTE) ======
# Nota: Para SSHPLUS proxy y pdirect ambos usan screen session "PDirect"
# porque así lo tenés probado.
write_services_by_target(){
  case "$TARGET" in
    VPS-MX)
      if [[ "${RUN_PD:-0}" -eq 1 ]]; then
        local svc="$SYSTEMD_DIR/$PD_SVC"
        backup_once "$svc"
        cat > "$svc" <<EOF
[Unit]
Description=Ejecutar PDirect en una sesión de screen
After=network.target

[Service]
ExecStart=/usr/bin/screen -DmS PDirect python ${DEST}/PDirect.py
WorkingDirectory=${DEST}
User=root
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        ok "Servicio PDirect (VPS-MX) listo."
      fi
      ;;
    SSHPLUS)
      if [[ "${RUN_PX:-0}" -eq 1 ]]; then
        local svc="$SYSTEMD_DIR/$PX_SVC"
        backup_once "$svc"
        cat > "$svc" <<EOF
[Unit]
Description=Ejecutar proxy en una sesión de screen
After=network.target

[Service]
ExecStart=/usr/bin/screen -DmS PDirect /usr/bin/python3 ${DEST}/proxy.py
WorkingDirectory=${DEST}
User=root
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        ok "Servicio proxy (SSHPLUS) listo."
      fi

      if [[ "${RUN_PD:-0}" -eq 1 ]]; then
        local svc="$SYSTEMD_DIR/$PD_SVC"
        backup_once "$svc"
        cat > "$svc" <<EOF
[Unit]
Description=Ejecutar PDirect en una sesión de screen
After=network.target

[Service]
ExecStart=/usr/bin/screen -DmS PDirect /usr/bin/python3 ${DEST}/PDirect.py
WorkingDirectory=${DEST}
User=root
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        ok "Servicio PDirect (SSHPLUS) listo."
      fi
      ;;
    ADMRufu)
      if [[ "${RUN_PD:-0}" -eq 1 ]]; then
        local svc="$SYSTEMD_DIR/$PD_SVC"
        backup_once "$svc"
        cat > "$svc" <<EOF
[Unit]
Description=Ejecutar PDirect en una sesión de screen
After=network.target

[Service]
ExecStart=/usr/bin/screen -DmS PDirect /usr/bin/python3 ${DEST}/PDirect.py
WorkingDirectory=${DEST}
User=root
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        ok "Servicio PDirect (ADMRufu) listo."
      fi
      ;;
    VPS-AGN)
      if [[ "${RUN_PD:-0}" -eq 1 ]]; then
        local svc="$SYSTEMD_DIR/$PD_SVC"
        backup_once "$svc"
        cat > "$svc" <<EOF
[Unit]
Description=Ejecutar PDirect en segundo plano
After=network.target

[Service]
Type=simple
WorkingDirectory=${DEST}
ExecStart=/usr/bin/env python3 ${DEST}/PDirect.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        ok "Servicio PDirect (VPS-AGN) listo."
      fi
      ;;
    LATAM)
      # Si tu LATAM usa otra plantilla distinta, la ajustamos.
      if [[ "${RUN_PD:-0}" -eq 1 ]]; then
        local svc="$SYSTEMD_DIR/$PD_SVC"
        backup_once "$svc"
        cat > "$svc" <<EOF
[Unit]
Description=Ejecutar PDirect en una sesión de screen
After=network.target

[Service]
ExecStart=/usr/bin/screen -DmS PDirect /usr/bin/python3 ${DEST}/PDirect.py
WorkingDirectory=${DEST}
User=root
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        ok "Servicio PDirect (LATAM) listo."
      fi
      ;;
  esac
}

# ---- BadVPN ----
write_badvpn_env_default(){
  mkdir -p /etc/default
  [[ -f "$BAD_ENV" ]] || echo "BADVPN_PORT=${BAD_DEFAULT_PORT}" > "$BAD_ENV"
  chmod 644 "$BAD_ENV"
}

write_service_badvpn(){
  local svc="$SYSTEMD_DIR/$BAD_SVC"
  backup_once "$svc"
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
}

daemon_reload(){ systemctl daemon-reload >/dev/null 2>&1 || true; }

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
  ok "Autostart HABILITADO."
}

disable_boot(){
  systemctl disable "$PD_SVC" >/dev/null 2>&1 || true
  systemctl disable "$PX_SVC" >/dev/null 2>&1 || true
  systemctl disable "$BAD_SVC" >/dev/null 2>&1 || true
  ok "Autostart DESHABILITADO."
}

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

# STATUS REAL
is_screen_running(){
  local name="$1"
  screen -ls 2>/dev/null | grep -qE "[0-9]+\.$name" && echo "RUNNING" || echo "OFF"
}

listen_ports_by_prog(){
  local prog="$1"
  if has_cmd netstat; then
    netstat -tnpl 2>/dev/null | awk -v p="$prog" '$6=="LISTEN" && $7 ~ p {print $4}' \
      | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq | paste -sd, - || echo "-"
  elif has_cmd ss; then
    ss -lntp 2>/dev/null | awk -v p="$prog" '$0 ~ p {print $4}' \
      | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq | paste -sd, - || echo "-"
  else
    echo "-"
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
  else
    echo "⚠️  No hay instalación registrada (igual detecto procesos/puertos)."
  fi
  echo

  local pd_run px_run py_ports bad_ports bp
  pd_run="$(is_screen_running "PDirect")"
  px_run="$(is_screen_running "Proxy")"
  py_ports="$(listen_ports_by_prog "python3")"
  bad_ports="$(listen_ports_by_prog "badvpn-udpgw")"
  bp="$(badvpn_port_current)"

  echo "PDirect: ${pd_run} | unit: $(svc_enabled "$PD_SVC") | python LISTEN: ${py_ports}"
  echo "proxy:   ${px_run} | unit: $(svc_enabled "$PX_SVC") | python LISTEN: ${py_ports}"
  echo "BadVPN:  unit: $(svc_enabled "$BAD_SVC") | port: ${bp} | badvpn LISTEN: ${bad_ports}"
  echo
  echo "📌 Comandos: pdmenu / automenu"
  echo
}

# LOGS: FIX definitivo (systemctl cat)
unit_exists(){
  systemctl cat "$1" >/dev/null 2>&1
}

unit_hint(){
  echo "👉 Para ver el unit file: systemctl cat $1"
  echo "👉 Para ver estado:      systemctl status $1 --no-pager -l"
}

show_related_units(){
  echo "Unidades relacionadas encontradas:"
  systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -E 'pdirect|proxy|badvpn|dropbear|ssh' || true
}

do_logs(){
  echo
  echo "Logs (últimas 80 líneas):"
  echo "  1) PDirect"
  echo "  2) proxy"
  echo "  3) BadVPN"
  echo "  4) Ver unidades detectadas (por instalaciones previas)"
  read -r -p "Opción: " o

  case "$o" in
    1)
      if unit_exists "$PD_SVC"; then
        journalctl -u "$PD_SVC" --no-pager -n 80 || true
      else
        echo "⚠️  No existe la unidad (systemd): $PD_SVC"
        show_related_units
        unit_hint "$PD_SVC" || true
      fi
      ;;
    2)
      if unit_exists "$PX_SVC"; then
        journalctl -u "$PX_SVC" --no-pager -n 80 || true
      else
        echo "⚠️  No existe la unidad (systemd): $PX_SVC"
        show_related_units
        unit_hint "$PX_SVC" || true
      fi
      ;;
    3)
      if unit_exists "$BAD_SVC"; then
        journalctl -u "$BAD_SVC" --no-pager -n 80 || true
      else
        echo "⚠️  No existe la unidad (systemd): $BAD_SVC"
        show_related_units
        unit_hint "$BAD_SVC" || true
      fi
      ;;
    4) show_related_units ;;
    *) echo "Opción inválida." ;;
  esac
}

# Edit manual
ensure_dest_from_state(){
  if ! load_state; then
    warn "No hay instalación registrada. Elegí sistema para saber la ruta."
    pick_target
    RUN_PD=1; RUN_PX=1; RUN_BAD=0
    persist_state
  fi
  mkdir -p "$DEST"
}

edit_menu(){
  need_root
  ensure_dest_from_state
  echo
  echo "Editar redireccionamiento (manual):"
  echo "  1) Editar PDirect.py  (nano ${DEST}/PDirect.py)"
  echo "  2) Editar proxy.py    (nano ${DEST}/proxy.py)"
  echo "  0) Volver"
  read -r -p "Opción: " e
  case "$e" in
    1) nano "${DEST}/PDirect.py" ;;
    2) nano "${DEST}/proxy.py" ;;
    0) return 0 ;;
    *) echo "Opción inválida." ;;
  esac
}

# Firewall UFW
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
    1) ufw allow 22/tcp >/dev/null 2>&1 || true; ufw --force enable >/dev/null 2>&1 || true ;;
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
      for p in $ports; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
      ufw --force enable >/dev/null 2>&1 || true
      ;;
    3) ufw status verbose || true ;;
    4) ufw disable || true ;;
    *) echo "Opción inválida." ;;
  esac
}

# Reiniciar SSH/DROPBEAR
restart_ssh_dropbear(){
  need_root
  echo
  echo "Reiniciar SSH / DROPBEAR"
  service dropbear stop 2>/dev/null || true
  service sshd restart 2>/dev/null || service ssh restart 2>/dev/null || true
  service dropbear start 2>/dev/null || true
  ok "SSH/DROPBEAR reiniciados."
}

# Acciones
do_install(){
  need_root
  ensure_deps
  install_commands

  free_ports_80_443

  pick_target
  ask_components

  ensure_assets
  copy_files

  write_services_by_target
  [[ "${RUN_BAD:-0}" -eq 1 ]] && { write_badvpn_env_default; write_service_badvpn; }

  daemon_reload
  enable_start_noblock
  persist_state
  ok "Instalación/actualización completada."
}

do_stop_all(){ systemctl stop "$PD_SVC" 2>/dev/null || true; systemctl stop "$PX_SVC" 2>/dev/null || true; systemctl stop "$BAD_SVC" 2>/dev/null || true; ok "Servicios detenidos."; }
do_start_all(){ systemctl start --no-block "$PD_SVC" 2>/dev/null || true; systemctl start --no-block "$PX_SVC" 2>/dev/null || true; systemctl start --no-block "$BAD_SVC" 2>/dev/null || true; ok "Servicios iniciados."; }
do_restart_all(){ systemctl restart --no-block "$PD_SVC" 2>/dev/null || true; systemctl restart --no-block "$PX_SVC" 2>/dev/null || true; systemctl restart --no-block "$BAD_SVC" 2>/dev/null || true; ok "Servicios reiniciados."; }

badvpn_set_port(){
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
}

do_uninstall(){
  systemctl stop "$PD_SVC" 2>/dev/null || true
  systemctl disable "$PD_SVC" 2>/dev/null || true
  systemctl stop "$PX_SVC" 2>/dev/null || true
  systemctl disable "$PX_SVC" 2>/dev/null || true
  systemctl stop "$BAD_SVC" 2>/dev/null || true
  systemctl disable "$BAD_SVC" 2>/dev/null || true
  rm -f "$SYSTEMD_DIR/$PD_SVC" "$SYSTEMD_DIR/$PX_SVC" "$SYSTEMD_DIR/$BAD_SVC"
  daemon_reload
  ok "Servicios removidos."
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
    echo "[1] 🛠️  Instalar / Actualizar (services por sistema, rutas correctas)"
    echo "[2] 🔓 Liberar puertos 80/443"
    echo "[3] ⛔  Detener TODO"
    echo "[4] ▶️  Reanudar TODO"
    echo "[5] 🔄 Reiniciar TODO"
    echo "[6] 📜 Ver logs"
    echo "[7] 🧨 Desinstalar servicios"
    echo "[8] 🔧 Cambiar puerto BadVPN (default 7300)"
    echo "[9] 🛡️  Firewall UFW (permitir puertos)"
    echo "[10] ✅ Habilitar autostart al reinicio"
    echo "[11] ⛔ Deshabilitar autostart"
    echo "[12] ✏️  Editar redireccionamiento (nano PDirect/proxy)"
    echo "[13] 🔁 Reiniciar SSH / DROPBEAR (fix puerto 22 y root directo)"
    echo "[0] Salir"
    echo
    read -r -p "Opción: " op
    case "$op" in
      1) run_step "Instalar/Actualizar" do_install ;;
      2) run_step "Liberar 80/443" free_ports_80_443 ;;
      3) run_step "Detener TODO" do_stop_all ;;
      4) run_step "Reanudar TODO" do_start_all ;;
      5) run_step "Reiniciar TODO" do_restart_all ;;
      6) run_step "Ver logs" do_logs ;;
      7) run_step "Desinstalar" do_uninstall ;;
      8) run_step "Cambiar puerto BadVPN" badvpn_set_port ;;
      9) run_step "Firewall UFW" firewall_menu ;;
      10) run_step "Enable autostart" enable_boot ;;
      11) run_step "Disable autostart" disable_boot ;;
      12) run_step "Editar PDirect/proxy" edit_menu ;;
      13) run_step "Reiniciar SSH/DROPBEAR" restart_ssh_dropbear ;;
      0) exit 0 ;;
      *) echo "Opción inválida."; press_enter ;;
    esac
  done
}

menu
