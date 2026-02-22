#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
#  El NeNe 3.0 – Script Automatizado de Redireccionamiento
#  - Modo manual-compatible: systemd + screen -DmS
#  - NO pregunta puertos de PDirect/proxy (ya están en el .py)
#  - BadVPN: 7300 por defecto (editable desde menú)
#  - One-liner friendly: descarga assets desde GitHub raw
# ==========================================================

APP_NAME="El NeNe 3.0 – Redireccionamiento de Puertos"

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

# Services
PD_SVC="pdirect.service"
PX_SVC="proxy.service"

# BadVPN
BAD_SVC="badvpn-udpgw.service"
BAD_BIN="/bin/badvpn-udpgw"
BAD_WRAPPER="/bin/antcrashvpn.sh"
BAD_ENV="/etc/default/nene3-badvpn"
BAD_DEFAULT_PORT="7300"

STATE_FILE="/var/lib/nene3/target.conf"
GLOBAL_CMD="/usr/local/bin/nene3"

ts(){ date +"%Y%m%d%H%M%S"; }
die(){ echo "❌ $*"; exit 1; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️  $*"; }

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

ensure_deps(){
  command -v python3 >/dev/null 2>&1 || die "Falta python3 (sudo apt-get update && sudo apt-get install -y python3)"
  command -v systemctl >/dev/null 2>&1 || die "No encuentro systemctl (systemd)."
  command -v curl >/dev/null 2>&1 || die "Falta curl (sudo apt-get install -y curl)"
  command -v screen >/dev/null 2>&1 || die "Falta screen (sudo apt-get update && sudo apt-get install -y screen)"
}

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
    # Por defecto 7300, podés cambiar luego en menú
    if [[ -f "$BAD_ENV" ]]; then
      BAD_PORT="$(grep -E '^BADVPN_PORT=' "$BAD_ENV" | cut -d= -f2 | tr -d '[:space:]' || true)"
      BAD_PORT="${BAD_PORT:-$BAD_DEFAULT_PORT}"
    else
      BAD_PORT="$BAD_DEFAULT_PORT"
    fi
  else
    RUN_BAD=0
    BAD_PORT=""
  fi
}

persist_state(){
  mkdir -p "$(dirname "$STATE_FILE")"
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

download_asset(){
  local name="$1"
  local url="${RAW_BASE}/files/${name}"
  local out="${DL_DIR}/${name}"
  mkdir -p "$DL_DIR"
  # IMPORTANTE: esto va a STDERR para no romper variables
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

copy_files(){
  echo
  echo "📁 Destino: $DEST"
  mkdir -p "$DEST"  # crea si no existe

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

write_service_pdirect(){
  local svc="$SYSTEMD_DIR/$PD_SVC"
  backup_if_exists "$svc"

  # Igual que tu método manual: screen -DmS
  cat > "$svc" <<EOF
[Unit]
Description=El NeNe 3.0 - PDirect (${TARGET}) via screen
After=network.target

[Service]
Type=forking
WorkingDirectory=${DEST}
ExecStart=/usr/bin/screen -DmS PDirect /usr/bin/python3 ${DEST}/PDirect.py
User=root
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  ok "Servicio creado: $PD_SVC"
}

write_service_proxy(){
  local svc="$SYSTEMD_DIR/$PX_SVC"
  backup_if_exists "$svc"

  # Igual que tu método manual: screen -DmS
  cat > "$svc" <<EOF
[Unit]
Description=El NeNe 3.0 - proxy (${TARGET}) via screen
After=network.target

[Service]
Type=forking
WorkingDirectory=${DEST}
ExecStart=/usr/bin/screen -DmS Proxy /usr/bin/python3 ${DEST}/proxy.py
User=root
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  ok "Servicio creado: $PX_SVC"
}

write_badvpn_env(){
  mkdir -p /etc/default
  local port="${BAD_DEFAULT_PORT}"
  if [[ -f "$BAD_ENV" ]]; then
    local v
    v="$(grep -E '^BADVPN_PORT=' "$BAD_ENV" | cut -d= -f2 | tr -d '[:space:]' || true)"
    port="${v:-$BAD_DEFAULT_PORT}"
  fi
  echo "BADVPN_PORT=${port}" > "$BAD_ENV"
  chmod 644 "$BAD_ENV"
  ok "BadVPN env listo (puerto=${port})"
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

daemon_reload(){ systemctl daemon-reload; }

enable_start(){
  [[ "$RUN_PD" -eq 1 ]] && systemctl enable --now "$PD_SVC"
  [[ "$RUN_PX" -eq 1 ]] && systemctl enable --now "$PX_SVC"
  [[ "${RUN_BAD:-0}" -eq 1 ]] && systemctl enable --now "$BAD_SVC"
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

get_default_host(){
  local f="$1"
  [[ -f "$f" ]] || { echo "-"; return; }
  local v
  v="$(grep -E "^[[:space:]]*DEFAULT_HOST[[:space:]]*=" -m1 "$f" 2>/dev/null | sed -E "s/.*=[[:space:]]*'([^']+)'.*/\1/")"
  [[ -n "$v" ]] && echo "$v" || echo "-"
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

  echo "PDirect: $(svc_state "$PD_SVC") | $(svc_enabled "$PD_SVC")"
  echo "proxy:   $(svc_state "$PX_SVC") | $(svc_enabled "$PX_SVC")"

  if systemctl list-unit-files | grep -q "^${BAD_SVC}"; then
    echo "BadVPN:  $(svc_state "$BAD_SVC") | $(svc_enabled "$BAD_SVC") | port: 127.0.0.1:$(badvpn_port_current)"
  else
    echo "BadVPN:  NO INSTALADO"
  fi
  echo
}

install_global_cmd(){
  cat > "$GLOBAL_CMD" <<EOF
#!/usr/bin/env bash
curl -fsSL "${RAW_BASE}/el-nene3.sh" | sudo bash
EOF
  chmod +x "$GLOBAL_CMD"
  ok "Comando global instalado: nene3"
}

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
    write_badvpn_env
    write_service_badvpn
  fi

  daemon_reload
  enable_start
  persist_state
  install_global_cmd

  ok "Instalación/actualización completada."
  show_status
}

do_stop_all(){
  need_root
  systemctl stop "$PD_SVC" 2>/dev/null || true
  systemctl stop "$PX_SVC" 2>/dev/null || true
  systemctl stop "$BAD_SVC" 2>/dev/null || true
  ok "Servicios detenidos."
}

do_start_all(){
  need_root
  systemctl start "$PD_SVC" 2>/dev/null || true
  systemctl start "$PX_SVC" 2>/dev/null || true
  systemctl start "$BAD_SVC" 2>/dev/null || true
  ok "Servicios iniciados."
}

do_restart_all(){
  need_root
  systemctl restart "$PD_SVC" 2>/dev/null || true
  systemctl restart "$PX_SVC" 2>/dev/null || true
  systemctl restart "$BAD_SVC" 2>/dev/null || true
  ok "Servicios reiniciados."
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
}

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
