#!/bin/bash
################################################################################
#
#  Script de instalación de Odoo - Overload Solutions
#  --------------------------------------------------
#  Instalador BASE de Overload Solutions:
#                - Odoo Community  (rama OE_VERSION)
#                - Odoo Enterprise (rama OE_VERSION, opcional)
#
#  Este script NO instala localizaciones ni addons custom: el servidor queda
#  con Odoo base (Community + Enterprise). Las localizaciones y los addons
#  custom se cargan después como paso separado.
#
#  Versiones soportadas: 12.0 a 19.0 vía OE_VERSION (por defecto 19.0).
#  La versión de Python del sistema debe ser compatible con la versión de
#  Odoo elegida — el script lo verifica y aborta si no cuadra:
#
#      Odoo 12          ->  Ubuntu 18.04  (Python 3.6/3.7)
#      Odoo 13 - 15     ->  Ubuntu 20.04  (Python 3.8)
#      Odoo 16 - 17     ->  Ubuntu 22.04  (Python 3.10)
#      Odoo 18 - 19     ->  Ubuntu 24.04  (Python 3.12)
#
#  Probado (19.0) en: Ubuntu 24.04 LTS (noble) | Python 3.12 | PostgreSQL 16
#
#  Uso:
#    sudo bash odoo_install.sh                   # Odoo 19.0
#    sudo OE_VERSION=17.0 bash odoo_install.sh   # Odoo 17.0
#
#  Variables que se pueden sobreescribir antes de invocar:
#    OE_VERSION        (12.0 ... 19.0 -- por defecto 19.0)
#    DB_PASSWORD       (contraseña del usuario Postgres)
#    OE_SUPERADMIN     (master password de Odoo)
#    IS_ENTERPRISE     (True/False -- por defecto True)
#    INSTALL_WKHTMLTOPDF (True/False)
#    OE_PORT           (por defecto 8069)
#    OE_CONFIG         (nombre del servicio/config -- por defecto odoo-server)
#    SKIP_PY_CHECK     (True para saltar la verificación de Python)
#
#  IMPORTANTE - PRE-REQUISITO DE SSH (solo si IS_ENTERPRISE=True):
#  La clave SSH de root (o un deploy key) debe tener acceso a:
#     * git@github.com:odoo/enterprise.git
#
################################################################################

set -e

#==============================================================================#
# 0. Variables de configuración
#==============================================================================#
OE_USER="odoo"
OE_HOME="/${OE_USER}"

OE_VERSION="${OE_VERSION:-19.0}"
case "${OE_VERSION}" in
  12.0|13.0|14.0|15.0|16.0|17.0|18.0|19.0) ;;
  *) echo "[FATAL] OE_VERSION='${OE_VERSION}' no soportada (use 12.0 ... 19.0)" >&2
     exit 1 ;;
esac
OE_MAJOR="${OE_VERSION%%.*}"

OE_DEPLOY_DIR="/odoo${OE_MAJOR}"                               # raíz del deploy
OE_HOME_EXT="${OE_DEPLOY_DIR}/${OE_USER}${OE_MAJOR}-server"    # carpeta con odoo-bin
OE_PORT="${OE_PORT:-8069}"

# Un servidor = una versión de Odoo. Si algún día conviven dos versiones en
# la misma máquina, sobreescribir OE_CONFIG y OE_PORT para la segunda.
OE_CONFIG="${OE_CONFIG:-${OE_USER}-server}"                    # /etc/odoo-server.conf

# Secrets - se pueden inyectar por env
OE_SUPERADMIN="${OE_SUPERADMIN:-admin}"
DB_USER="${DB_USER:-odoo${OE_MAJOR}}"
DB_PASSWORD="${DB_PASSWORD:-admin}"

# Repos remotos
CORE_REPO="https://github.com/odoo/odoo.git"
ENTERPRISE_REPO="${ENTERPRISE_REPO:-git@github.com:odoo/enterprise.git}"
ENTERPRISE_DIR="${OE_DEPLOY_DIR}/odoo_enterprise"

# Logs
LOG_DIR="/var/log/odoo${OE_MAJOR}"
LOG_FILE="${LOG_DIR}/odoo.log"

# Flags
INSTALL_WKHTMLTOPDF="${INSTALL_WKHTMLTOPDF:-True}"
IS_ENTERPRISE="${IS_ENTERPRISE:-True}"

#==============================================================================#
# Helpers
#==============================================================================#
say()   { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
fatal() { echo -e "\033[1;31m[FATAL]\033[0m $*" >&2; exit 1; }

# git corre como ROOT (la clave SSH del pre-requisito es la de root) y la
# propiedad se corrige después con chown -R. accept-new evita que el primer
# contacto con github.com se quede esperando el known_hosts; safe.directory
# permite a root hacer pull en repos ya chowneados al usuario odoo.
clone_or_pull() {
  local repo="$1" dir="$2" branch="$3"
  export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
  if [ -d "${dir}/.git" ]; then
    echo "    [skip-clone] ${dir} ya existe, intentando git pull ..."
    git -C "${dir}" -c safe.directory="${dir}" pull --ff-only || \
      warn "git pull falló en ${dir} (continuamos)"
  else
    echo "    Clonando ${repo} -> ${dir} (rama ${branch}) ..."
    git clone --depth=1 -b "${branch}" "${repo}" "${dir}"
  fi
}

#==============================================================================#
# Comprobaciones previas
#==============================================================================#
[ "$(id -u)" -eq 0 ] || fatal "Este script debe ejecutarse como root (sudo bash ${0})"

# --- Compatibilidad Python <-> Odoo ------------------------------------------
# Rango de Python soportado (min y max inclusive) por versión de Odoo.
py_range() {
  case "$1" in
    12.0) echo "3.5 3.7"  ;;
    13.0) echo "3.6 3.8"  ;;
    14.0) echo "3.6 3.9"  ;;
    15.0) echo "3.8 3.10" ;;
    16.0) echo "3.8 3.11" ;;
    17.0) echo "3.10 3.12" ;;
    18.0) echo "3.10 3.12" ;;
    19.0) echo "3.10 3.13" ;;
  esac
}
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

PY_VER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
if [ -z "${PY_VER}" ]; then
  warn "python3 no está instalado todavía; se usará el de la distro (paso 3) sin verificar."
else
  read -r PY_MIN PY_MAX <<< "$(py_range "${OE_VERSION}")"
  if ! ver_ge "${PY_VER}" "${PY_MIN}" || ! ver_ge "${PY_MAX}" "${PY_VER}"; then
    warn "Odoo ${OE_VERSION} necesita Python ${PY_MIN} a ${PY_MAX}; este sistema tiene ${PY_VER}."
    warn "Ubuntu recomendado: 12 -> 18.04 | 13-15 -> 20.04 | 16-17 -> 22.04 | 18-19 -> 24.04"
    [ "${SKIP_PY_CHECK:-False}" = "True" ] || \
      fatal "Versión de Python incompatible (SKIP_PY_CHECK=True para forzar bajo su riesgo)."
  fi
fi

say "Sistema detectado: $(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
say "Odoo:             ${OE_VERSION} (Enterprise: ${IS_ENTERPRISE})"
say "Python:           $(python3 --version 2>&1)"
say "Deploy dir:       ${OE_DEPLOY_DIR}"
say "Usuario sistema:  ${OE_USER}"
say "Usuario DB:       ${DB_USER}"

#==============================================================================#
# 1. Sistema base
#==============================================================================#
say "1. Actualizando paquetes del sistema ..."
apt-get update -y
apt-get upgrade -y

#==============================================================================#
# 2. PostgreSQL
#==============================================================================#
# Se instala la versión por defecto de la distro: cada Ubuntu recomendado trae
# el PostgreSQL adecuado a su época de Odoo (18.04->10, 20.04->12, 22.04->14,
# 24.04->16).
say "2. Instalando PostgreSQL (versión por defecto de la distro) y libpq-dev ..."
apt-get install -y libpq-dev postgresql

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  echo "    Creando rol Postgres '${DB_USER}' con permiso CREATEDB ..."
  sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH CREATEDB PASSWORD '${DB_PASSWORD}';"
else
  echo "    Rol Postgres '${DB_USER}' ya existe (no se modifica)."
fi

#==============================================================================#
# 3. Python + librerías del sistema
#==============================================================================#
say "3. Instalando Python 3 y dependencias del sistema ..."
apt-get install -y python3 python3-pip

# --- Paquetes base del sistema ----------------------------------------------
apt-get install -y git python3-cffi build-essential wget python3-dev \
                   python3-venv python3-wheel libxslt-dev libzip-dev \
                   libldap2-dev libsasl2-dev python3-setuptools node-less \
                   libpng-dev libjpeg-dev gdebi

#==============================================================================#
# 4. Node.js + npm + rtlcss + less   <<<< CRÍTICO para CSS/assets >>>>
#==============================================================================#
say "4. Instalando Node.js + npm + rtlcss + less ..."
apt-get install -y nodejs npm

#   rtlcss:  imprescindible. Sin él, Odoo no puede generar el bundle
#            'web.assets_*.rtl.css' y al cargar /web aparecen errores
#            tipo 'rtlcss: command not found' en el log y el navegador
#            queda sin estilos (esa es la causa #1 del 'error de CSS').
echo "    Instalando rtlcss globalmente ..."
npm install -g rtlcss

#   less / less-plugin-clean-css:
#   Se instalan SIEMPRE (no solo con Enterprise) para no fallar al
#   compilar temas .less.
echo "    Instalando less y less-plugin-clean-css globalmente ..."
npm install -g less less-plugin-clean-css

#==============================================================================#
# 5. wkhtmltopdf (necesario para reportes PDF)
#==============================================================================#
if [ "${INSTALL_WKHTMLTOPDF}" = "True" ]; then
  say "5. Instalando wkhtmltopdf ..."
  apt-get install -y wkhtmltopdf
else
  say "5. wkhtmltopdf saltado por configuración (INSTALL_WKHTMLTOPDF=False)"
fi

#==============================================================================#
# 6. Usuario del sistema 'odoo'
#==============================================================================#
say "6. Verificando usuario del sistema '${OE_USER}' ..."
if ! id "${OE_USER}" >/dev/null 2>&1; then
  echo "    Creando usuario ${OE_USER} con home ${OE_HOME} ..."
  adduser --system --quiet --shell=/bin/bash --home="${OE_HOME}" \
          --gecos 'ODOO' --group "${OE_USER}"
else
  echo "    Usuario ${OE_USER} ya existe."
fi

#==============================================================================#
# 7. Clonado del código fuente
#==============================================================================#
say "7. Preparando ${OE_DEPLOY_DIR} ..."
mkdir -p "${OE_DEPLOY_DIR}"
chown "${OE_USER}:${OE_USER}" "${OE_DEPLOY_DIR}"

say "7.1 Odoo Community (rama ${OE_VERSION}) -> ${OE_HOME_EXT}"
clone_or_pull "${CORE_REPO}" "${OE_HOME_EXT}" "${OE_VERSION}"

if [ "${IS_ENTERPRISE}" = "True" ]; then
  say "7.2 Odoo Enterprise (requiere acceso SSH a odoo/enterprise) -> ${ENTERPRISE_DIR}"
  clone_or_pull "${ENTERPRISE_REPO}" "${ENTERPRISE_DIR}" "${OE_VERSION}"
fi

chown -R "${OE_USER}:${OE_USER}" "${OE_DEPLOY_DIR}"

#==============================================================================#
# 8. Requirements de Python (oficiales de la versión + extras Overload)
#==============================================================================#
say "8. Instalando requirements de Odoo ${OE_VERSION} ..."

# pip moderno (Ubuntu >= 23.04) exige --break-system-packages por PEP-668;
# pip viejo (Ubuntu 18.04/20.04) no conoce esa opción.
PIP_FLAGS=""
if pip3 install --help 2>/dev/null | grep -q "break-system-packages"; then
  PIP_FLAGS="--break-system-packages"
fi

# Los requirements oficiales se toman del árbol clonado: así corresponden
# SIEMPRE exactamente a la versión de Odoo elegida.
pip3 install ${PIP_FLAGS} -r "${OE_HOME_EXT}/requirements.txt"

# Extras Overload: faltan en el oficial y sin ellos Odoo da errores de
# assets/CSS. Si el repo odoo_install fue clonado se usa su requirements.txt
# (solo extras); si se descargó únicamente el script, va la lista inline.
REQ_EXTRAS="$(dirname "$(readlink -f "$0")")/requirements.txt"
if [ -f "${REQ_EXTRAS}" ]; then
  echo "    Extras desde ${REQ_EXTRAS}"
  pip3 install ${PIP_FLAGS} -r "${REQ_EXTRAS}"
else
  echo "    Extras inline (beautifulsoup4, numpy, xmltodict, pycountry) ..."
  pip3 install ${PIP_FLAGS} beautifulsoup4 numpy xmltodict pycountry
fi

#==============================================================================#
# 9. /etc/odoo-server.conf
#==============================================================================#
say "9. Generando /etc/${OE_CONFIG}.conf ..."

# Enterprise primero en el addons_path (recomendación oficial: sus módulos
# tienen prioridad sobre los de Community).
ADDONS_PATH="${OE_HOME_EXT}/addons"
[ "${IS_ENTERPRISE}" = "True" ] && ADDONS_PATH="${ENTERPRISE_DIR},${ADDONS_PATH}"

# Backup del config existente (si lo hay) antes de sobreescribirlo
if [ -f "/etc/${OE_CONFIG}.conf" ]; then
  cp "/etc/${OE_CONFIG}.conf" "/etc/${OE_CONFIG}.conf.bak-$(date +%Y%m%d-%H%M%S)"
fi

cat > "/etc/${OE_CONFIG}.conf" <<EOF
[options]
admin_passwd = ${OE_SUPERADMIN}
db_host = localhost
db_port = 5432
db_user = ${DB_USER}
db_password = ${DB_PASSWORD}
addons_path = ${ADDONS_PATH}
logfile = ${LOG_FILE}
http_interface = 0.0.0.0
http_port = ${OE_PORT}
EOF

chown "${OE_USER}:${OE_USER}" "/etc/${OE_CONFIG}.conf"
chmod 640 "/etc/${OE_CONFIG}.conf"

#==============================================================================#
# 10. Directorio de logs
#==============================================================================#
say "10. Creando directorio de logs ${LOG_DIR} ..."
mkdir -p "${LOG_DIR}"
chown "${OE_USER}:${OE_USER}" "${LOG_DIR}"

#==============================================================================#
# 11. Init script LSB (systemd compatible)
#
#     IMPORTANTE: el DAEMON apunta DIRECTAMENTE al binario real en
#     ${OE_HOME_EXT}/odoo-bin .  Si apunta a una ruta que no existe en
#     este deploy, al rebootear systemd marca el servicio como
#     'active (exited)' sin levantar nada.
#==============================================================================#
say "11. Generando /etc/init.d/${OE_CONFIG} ..."

cat > "/etc/init.d/${OE_CONFIG}" <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ${OE_CONFIG}
# Required-Start:    \$remote_fs \$syslog
# Required-Stop:     \$remote_fs \$syslog
# Should-Start:      \$network
# Should-Stop:       \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Enterprise Business Applications
# Description:       ODOO Business Applications
### END INIT INFO
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
DAEMON=${OE_HOME_EXT}/odoo-bin
NAME=${OE_CONFIG}
DESC=${OE_CONFIG}
USER=${OE_USER}
CONFIGFILE="/etc/${OE_CONFIG}.conf"
PIDFILE=/var/run/\${NAME}.pid
DAEMON_OPTS="-c \$CONFIGFILE"
[ -x \$DAEMON ]    || exit 0
[ -f \$CONFIGFILE ] || exit 0

checkpid() {
  [ -f \$PIDFILE ] || return 1
  pid=\$(cat \$PIDFILE)
  [ -d /proc/\$pid ] && return 0
  return 1
}

case "\${1}" in
  start)
    echo -n "Starting \${DESC}: "
    start-stop-daemon --start --quiet --pidfile \$PIDFILE --chuid \$USER \\
      --background --make-pidfile --exec \$DAEMON -- \$DAEMON_OPTS
    echo "\${NAME}."
    ;;
  stop)
    echo -n "Stopping \${DESC}: "
    start-stop-daemon --stop --quiet --pidfile \$PIDFILE --oknodo
    echo "\${NAME}."
    ;;
  restart|force-reload)
    echo -n "Restarting \${DESC}: "
    start-stop-daemon --stop --quiet --pidfile \$PIDFILE --oknodo
    sleep 1
    start-stop-daemon --start --quiet --pidfile \$PIDFILE --chuid \$USER \\
      --background --make-pidfile --exec \$DAEMON -- \$DAEMON_OPTS
    echo "\${NAME}."
    ;;
  *)
    N=/etc/init.d/\$NAME
    echo "Usage: \$NAME {start|stop|restart|force-reload}" >&2
    exit 1
    ;;
esac
exit 0
EOF

chmod +x "/etc/init.d/${OE_CONFIG}"
update-rc.d "${OE_CONFIG}" defaults
systemctl daemon-reload

#==============================================================================#
# 12. Arrancar el servicio y verificar
#==============================================================================#
say "12. Arrancando ${OE_CONFIG} ..."
systemctl restart "${OE_CONFIG}"
sleep 5

systemctl status "${OE_CONFIG}" --no-pager | head -10 || true

if ss -tlnp 2>/dev/null | grep -q ":${OE_PORT} "; then
  IP=$(hostname -I | awk '{print $1}')
  echo ""
  echo "================================================================"
  echo "  Odoo ${OE_VERSION} arriba en  http://${IP}:${OE_PORT}"
  echo "  master password: ${OE_SUPERADMIN}"
  echo "  log:             ${LOG_FILE}"
  echo "  config:          /etc/${OE_CONFIG}.conf"
  echo "  addons_path:     ${ADDONS_PATH}"
  echo "================================================================"
  echo ""
  echo "  Siguiente paso: cargar sus localizaciones / addons custom."
else
  warn "El puerto ${OE_PORT} no está escuchando. Revisar ${LOG_FILE}:"
  echo ""
  tail -20 "${LOG_FILE}" 2>/dev/null || true
  exit 1
fi
