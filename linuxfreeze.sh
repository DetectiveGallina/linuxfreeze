#!/usr/bin/env bash
# linuxfreeze.sh
# LINUXFREEZE - Congelamiento completo para estudiantes
# Uso: sudo ./linuxfreeze.sh <command> [user]
# Commands: set-password, freeze <user>, unfreeze <user>, status <user>
set -euo pipefail

# ---------------- CONFIG ----------------
LINUXFREEZE_DIR="/etc/linuxfreeze"
BACKUP_ROOT="$LINUXFREEZE_DIR/backup"
USER_FILE="$LINUXFREEZE_DIR/frozen_user"
PASSFILE="$LINUXFREEZE_DIR/password"
SALTFILE="$LINUXFREEZE_DIR/salt"
GROUPS_DIR="$LINUXFREEZE_DIR/groups"
RESTORE_SCRIPT="/usr/local/sbin/linux-restore.sh"
CLEANUP_SCRIPT="/usr/local/sbin/linux-cleanup.sh"
SYSTEMD_UNIT="/etc/systemd/system/linux-restore.service"
OPENRC_INIT="/etc/init.d/linux-restore"
CRON_TAG="#LINUXFREEZE_RESTORE"
# ----------------------------------------

# ---------- helpers ----------
log(){ echo "[LINUXFREEZE] $*"; }
need_root(){ [ "$(id -u)" -eq 0 ] || { echo "Ejecutá como root."; exit 1; }; }
sha256(){
  local input="$1"
  printf "%s" "${input}" | sha256sum | cut -d' ' -f1
}
init_detect(){
  if command -v rc-update >/dev/null 2>&1 && [ -d /run/openrc ]; then
    echo "openrc"
  elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    echo "systemd"
  else
    echo "sysv"
  fi
}
# --------------------------------

# ---------- password handling ----------
set_password(){
  need_root
  mkdir -p "$LINUXFREEZE_DIR"

  # Verificar sha256sum
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "ERROR: sha256sum no está instalado."
    exit 1
  fi

  read -rsp "Nueva contraseña: " p1; echo
  read -rsp "Repetir: " p2; echo

  if [ "$p1" != "$p2" ]; then
    echo "No coinciden.";
    exit 1
  fi

  if [ -z "$p1" ]; then
    echo "La contraseña no puede estar vacía."
    exit 1
  fi

  # Generar salt
  SALT=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | head -c 32)

  if [ -z "$SALT" ]; then
    echo "ERROR: No se pudo generar salt."
    exit 1
  fi

  # Crear archivos
  echo "$SALT" > "$SALTFILE"
  HASH=$(sha256 "${SALT}${p1}")
  echo "$HASH" > "$PASSFILE"
  chmod 600 "$PASSFILE" "$SALTFILE"

  log "Contraseña establecida correctamente."
}
check_password(){
  if [ ! -f "$PASSFILE" ] || [ ! -f "$SALTFILE" ]; then
    echo "No hay contraseña configurada. Ejecutá: $0 set-password"; exit 1
  fi
  read -rsp "Contraseña: " pw; echo
  SALT=$(cat "$SALTFILE")
  HASH=$(sha256 "${SALT}${pw}")
  STORED=$(cat "$PASSFILE")
  if [ "$HASH" != "$STORED" ]; then
    echo "Contraseña incorrecta."; exit 1
  fi
}
# ---------------------------------------

# ---------- cleanup script (limpia archivos temporales del usuario) ----------
install_cleanup_script(){
  need_root
  mkdir -p "$LINUXFREEZE_DIR"
  cat > "$CLEANUP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
USER_FILE="/etc/linuxfreeze/frozen_user"

[ -f "$USER_FILE" ] || exit 0
FUSER="$(cat "$USER_FILE" | tr -d '\n')"

# Limpiar archivos temporales del usuario congelado
[ -d "/tmp" ] && find /tmp -user "$FUSER" -delete 2>/dev/null || true
[ -d "/var/tmp" ] && find /var/tmp -user "$FUSER" -delete 2>/dev/null || true

# Limpiar cache común de aplicaciones
[ -d "/var/cache" ] && find /var/cache -user "$FUSER" -delete 2>/dev/null || true

# Terminar procesos del usuario (por si quedaron colgados)
pkill -u "$FUSER" 2>/dev/null || true

exit 0
EOF
  chmod 755 "$CLEANUP_SCRIPT"
  log "Script de limpieza instalado en $CLEANUP_SCRIPT"
}
# ---------------------------------------------

# ---------- restore script (restaura home completo) ----------
install_restore_script(){
  need_root
  mkdir -p "$LINUXFREEZE_DIR"
  cat > "$RESTORE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BACKUP_ROOT="/etc/linuxfreeze/backup"
USER_FILE="/etc/linuxfreeze/frozen_user"
CLEANUP_SCRIPT="/usr/local/sbin/linuxfreeze-cleanup.sh"
RSYNC="$(command -v rsync || true)"

if [ ! -x "$RSYNC" ]; then
  echo "rsync no disponible, restauración abortada." >&2
  exit 1
fi

[ -f "$USER_FILE" ] || exit 0
FUSER="$(cat "$USER_FILE" | tr -d '\n')"
SRC="$BACKUP_ROOT/$FUSER"
DST="/home/$FUSER"

# Primero ejecutar limpieza
[ -x "$CLEANUP_SCRIPT" ] && "$CLEANUP_SCRIPT"

# Restaurar home completo
if [ -d "$SRC" ]; then
  # Asegurarse que el usuario no esté logueado
  pkill -u "$FUSER" 2>/dev/null || true
  sleep 1

  # Restaurar con rsync (borra todo lo que no está en backup)
  "$RSYNC" -aHAX --numeric-ids --delete "$SRC/" "$DST/"
  chown -R "$FUSER:$FUSER" "$DST" 2>/dev/null || true

  echo "[LINUXFREEZE] Usuario $FUSER restaurado al estado original."
fi

exit 0
EOF
  chmod 755 "$RESTORE_SCRIPT"
  log "Script de restauración instalado en $RESTORE_SCRIPT"
}
# ---------------------------------------------

# ---------- install/remove autostart restore ----------
install_restore_mechanism(){
  need_root
  INIT="$(init_detect)"
  case "$INIT" in
    systemd)
      cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Ofris restore home para usuario congelado
After=local-fs.target
Before=display-manager.service gdm.service lightdm.service sddm.service

[Service]
Type=oneshot
ExecStart=$RESTORE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload || true
      systemctl enable linuxfreeze-restore.service || true
      log "Servicio systemd instalado y habilitado."
      ;;
    openrc)
      cat > "$OPENRC_INIT" <<EOF
#!/sbin/openrc-run

description="Ofris restore home para usuario congelado"

depend() {
    need localmount
    before xdm
}

start() {
    ebegin "Restaurando usuario congelado"
    $RESTORE_SCRIPT
    eend \$?
}
EOF
      chmod +x "$OPENRC_INIT"
      rc-update add linuxfreeze-restore boot || true
      log "Init OpenRC instalado y habilitado."
      ;;
    sysv)
      # rc.local fallback
      if [ -f /etc/rc.local ]; then
        if ! grep -qF "$RESTORE_SCRIPT" /etc/rc.local 2>/dev/null; then
          sed -i '/exit 0$/d' /etc/rc.local || true
          echo "$RESTORE_SCRIPT || true" >> /etc/rc.local
          echo "exit 0" >> /etc/rc.local
          chmod +x /etc/rc.local
          log "Agregado $RESTORE_SCRIPT a /etc/rc.local"
        fi
      else
        # fallback crontab @reboot for root
        (crontab -l -u root 2>/dev/null | grep -vF "$CRON_TAG" || true; echo "@reboot $RESTORE_SCRIPT $CRON_TAG") | crontab -u root -
        log "Agregado entrada @reboot en crontab root."
      fi
      ;;
  esac
}

remove_restore_mechanism(){
  need_root
  INIT="$(init_detect)"
  case "$INIT" in
    systemd)
      systemctl disable linuxfreeze-restore.service 2>/dev/null || true
      systemctl stop linuxfreeze-restore.service 2>/dev/null || true
      rm -f "$SYSTEMD_UNIT" || true
      systemctl daemon-reload || true
      log "Servicio systemd removido."
      ;;
    openrc)
      rc-update del linuxfreeze-restore boot 2>/dev/null || true
      rc-update del linuxfreeze-restore default 2>/dev/null || true
      rm -f "$OPENRC_INIT" || true
      log "Init OpenRC removido."
      ;;
    sysv)
      if [ -f /etc/rc.local ]; then
        sed -i "\|$RESTORE_SCRIPT|d" /etc/rc.local || true
        log "Removido de /etc/rc.local"
      fi
      crontab -l -u root 2>/dev/null | grep -vF "$CRON_TAG" | crontab -u root - 2>/dev/null || true
      log "Removida entrada de crontab."
      ;;
  esac
}
# ----------------------------------------------------

# ---------- freeze ----------
freeze_user(){
  need_root
  [ -n "${1:-}" ] || { echo "Uso: $0 freeze <usuario>"; exit 1; }
  FUSER="$1"
  check_password

  if ! id -u "$FUSER" >/dev/null 2>&1; then echo "Usuario $FUSER no existe."; exit 1; fi

  if [ -f "$USER_FILE" ]; then
    CUR="$(cat "$USER_FILE")"
    if [ "$CUR" = "$FUSER" ]; then
      echo "Usuario $FUSER ya está congelado."; exit 0
    else
      echo "Otro usuario ($CUR) ya está congelado. Descongelalo primero."; exit 1
    fi
  fi

  # check rsync
  if ! command -v rsync >/dev/null 2>&1; then echo "Instalá rsync antes."; exit 1; fi

  mkdir -p "$BACKUP_ROOT"
  mkdir -p "$GROUPS_DIR"

  # Terminar procesos del usuario antes de hacer backup
  pkill -u "$FUSER" 2>/dev/null || true
  sleep 1

  # save original groups
  id -nG "$FUSER" | tr ' ' '\n' > "$GROUPS_DIR/${FUSER}.groups" || true

  log "Creando backup COMPLETO de /home/$FUSER en $BACKUP_ROOT/$FUSER ..."
  rsync -aHAX --numeric-ids --delete "/home/$FUSER/" "$BACKUP_ROOT/$FUSER/"

  # remove from sudo/wheel
  if getent group sudo >/dev/null 2>&1; then
    gpasswd -d "$FUSER" sudo 2>/dev/null || true
  fi
  if getent group wheel >/dev/null 2>&1; then
    gpasswd -d "$FUSER" wheel 2>/dev/null || true
  fi

  # mark frozen
  echo "$FUSER" > "$USER_FILE"
  chmod 600 "$USER_FILE"

  # install scripts & mechanism
  install_cleanup_script
  install_restore_script
  install_restore_mechanism

  cat <<EOF

┌──────────────────────────────────────────────────────────────┐
│ ✓ Usuario $FUSER CONGELADO exitosamente
│
│ Qué se restaura en cada reinicio:
│  • Todo el contenido de /home/$FUSER
│  • Archivos temporales en /tmp y /var/tmp
│  • Procesos del usuario terminados
│
│ Recomendaciones para estudiantes:
│  • Guardar trabajos en pendrive/USB
│  • Usar 'git push' para respaldar código
│  • Todo lo local se BORRA al reiniciar
│
│ Para descongelar: sudo $0 unfreeze $FUSER
└──────────────────────────────────────────────────────────────┘

EOF
}
# --------------------------------

# ---------- unfreeze ----------
unfreeze_user(){
  need_root
  [ -n "${1:-}" ] || { echo "Uso: $0 unfreeze <usuario>"; exit 1; }
  FUSER="$1"
  check_password

  if [ ! -f "$USER_FILE" ]; then
    echo "No hay usuario congelado."; exit 0
  fi
  CUR="$(cat "$USER_FILE")"
  if [ "$CUR" != "$FUSER" ]; then
    echo "El usuario congelado es '$CUR', no '$FUSER'."; exit 1
  fi

  # restore original groups if we saved them
  if [ -f "$GROUPS_DIR/${FUSER}.groups" ]; then
    ORIG_GROUPS="$(cat "$GROUPS_DIR/${FUSER}.groups" | paste -sd ',')"
    usermod -a -G "$ORIG_GROUPS" "$FUSER" 2>/dev/null || true
    rm -f "$GROUPS_DIR/${FUSER}.groups" || true
  fi

  # remove frozen marker and backup
  rm -f "$USER_FILE"
  rm -rf "$BACKUP_ROOT/$FUSER"

  # remove restore mechanism
  remove_restore_mechanism

  # remove scripts
  rm -f "$RESTORE_SCRIPT" "$CLEANUP_SCRIPT"

  log "Usuario $FUSER descongelado. Eliminados backups y mecanismos de restauración."
}
# --------------------------------

# ---------- status ----------
status_user(){
  [ -n "${1:-}" ] || { echo "Uso: $0 status <usuario>"; exit 1; }
  FUSER="$1"
  if [ -f "$USER_FILE" ]; then
    CUR="$(cat "$USER_FILE")"
    if [ "$CUR" = "$FUSER" ]; then
      echo "┌─────────────────────────────────────────┐"
      echo "│ Estado: CONGELADO ❄️                    │"
      echo "│ Usuario: $FUSER"
      echo "│                                         │"
      echo "│ Se restaura en cada reinicio:           │"
      echo "│  • /home/$FUSER (completo)"
      echo "│  • Archivos temporales                  │"
      echo "└─────────────────────────────────────────┘"
    else
      echo "Usuario $FUSER NO está congelado."
      echo "Usuario congelado actual: $CUR"
    fi
  else
    echo "No hay usuario congelado en el sistema."
  fi
}
# --------------------------------

# ---------- main ----------
CMD="${1:-}"
case "$CMD" in
  set-password) set_password ;;
  freeze) freeze_user "${2:-}" ;;
  unfreeze) unfreeze_user "${2:-}" ;;
  status) status_user "${2:-}" ;;
  *)
    cat <<EOF
╔═══════════════════════════════════════════════════════════════╗
║       LINUXFREEZE - Sistema de Congelamiento para Linux       ║
╚═══════════════════════════════════════════════════════════════╝

Uso: $0 <command> [usuario]

Comandos:
  set-password          Establecer contraseña de administración
                        (requerido antes de freeze/unfreeze)

  freeze <usuario>      Congelar usuario (restaura todo en cada boot)

  unfreeze <usuario>    Descongelar usuario (vuelve a modo normal)

  status <usuario>      Mostrar estado actual del usuario

Ejemplo de uso:
  1. sudo $0 set-password
  2. sudo $0 freeze estudiante
  3. sudo $0 status estudiante

Compatible con: SystemD, OpenRC, SysVinit
EOF
    exit 1
    ;;
esac
exit 0
