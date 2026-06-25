#!/bin/bash
# Odoo Community installer (12.0 - 19.0)
# Wilfri Martinez <wmartinez@overloadsolutions.com.do>
# Soporte, localizacion y modulos a medida.

set -e

OE_USER="odoo"
OE_HOME="/${OE_USER}"

OE_VERSION="${OE_VERSION:-19.0}"
case "${OE_VERSION}" in
  12.0|13.0|14.0|15.0|16.0|17.0|18.0|19.0) ;;
  *) echo "[FATAL] OE_VERSION='${OE_VERSION}' no soportada (use 12.0 ... 19.0)" >&2
     exit 1 ;;
esac
OE_MAJOR="${OE_VERSION%%.*}"

OE_DEPLOY_DIR="/odoo${OE_MAJOR}"
OE_HOME_EXT="${OE_DEPLOY_DIR}/${OE_USER}${OE_MAJOR}-server"
OE_PORT="${OE_PORT:-8069}"

OE_CONFIG="${OE_CONFIG:-${OE_USER}-server}"

OE_SUPERADMIN="${OE_SUPERADMIN:-admin}"
DB_USER="${DB_USER:-odoo${OE_MAJOR}}"
DB_PASSWORD="${DB_PASSWORD:-admin}"

CORE_REPO="https://github.com/odoo/odoo.git"

LOG_DIR="/var/log/odoo${OE_MAJOR}"
LOG_FILE="${LOG_DIR}/odoo.log"

INSTALL_WKHTMLTOPDF="${INSTALL_WKHTMLTOPDF:-True}"

say()   { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
fatal() { echo -e "\033[1;31m[FATAL]\033[0m $*" >&2; exit 1; }

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

[ "$(id -u)" -eq 0 ] || fatal "Este script debe ejecutarse como root (sudo bash ${0})"

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
say "Odoo:             ${OE_VERSION} (Community)"
say "Python:           $(python3 --version 2>&1)"
say "Deploy dir:       ${OE_DEPLOY_DIR}"
say "Usuario sistema:  ${OE_USER}"
say "Usuario DB:       ${DB_USER}"

say "1. Actualizando paquetes del sistema ..."
apt-get update -y
apt-get upgrade -y

say "2. Instalando PostgreSQL (versión por defecto de la distro) y libpq-dev ..."
apt-get install -y libpq-dev postgresql

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  echo "    Creando rol Postgres '${DB_USER}' con permiso CREATEDB ..."
  sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH CREATEDB PASSWORD '${DB_PASSWORD}';"
else
  echo "    Rol Postgres '${DB_USER}' ya existe (no se modifica)."
fi

say "3. Instalando Python 3 y dependencias del sistema ..."
apt-get install -y python3 python3-pip

apt-get install -y git python3-cffi build-essential wget python3-dev \
                   python3-venv python3-wheel libxslt-dev libzip-dev \
                   libldap2-dev libsasl2-dev python3-setuptools node-less \
                   libpng-dev libjpeg-dev gdebi

say "4. Instalando Node.js + npm + rtlcss + less ..."
apt-get install -y nodejs npm

echo "    Instalando rtlcss globalmente ..."
npm install -g rtlcss

echo "    Instalando less y less-plugin-clean-css globalmente ..."
npm install -g less less-plugin-clean-css

if [ "${INSTALL_WKHTMLTOPDF}" = "True" ]; then
  say "5. Instalando wkhtmltopdf ..."
  apt-get install -y wkhtmltopdf
else
  say "5. wkhtmltopdf saltado por configuración (INSTALL_WKHTMLTOPDF=False)"
fi

say "6. Verificando usuario del sistema '${OE_USER}' ..."
if ! id "${OE_USER}" >/dev/null 2>&1; then
  echo "    Creando usuario ${OE_USER} con home ${OE_HOME} ..."
  adduser --system --quiet --shell=/bin/bash --home="${OE_HOME}" \
          --gecos 'ODOO' --group "${OE_USER}"
else
  echo "    Usuario ${OE_USER} ya existe."
fi

say "7. Preparando ${OE_DEPLOY_DIR} ..."
mkdir -p "${OE_DEPLOY_DIR}"
chown "${OE_USER}:${OE_USER}" "${OE_DEPLOY_DIR}"

say "7.1 Odoo Community (rama ${OE_VERSION}) -> ${OE_HOME_EXT}"
clone_or_pull "${CORE_REPO}" "${OE_HOME_EXT}" "${OE_VERSION}"

chown -R "${OE_USER}:${OE_USER}" "${OE_DEPLOY_DIR}"

say "8. Instalando requirements de Odoo ${OE_VERSION} ..."

PIP_FLAGS="--ignore-installed"
if pip3 install --help 2>/dev/null | grep -q "break-system-packages"; then
  PIP_FLAGS="${PIP_FLAGS} --break-system-packages"
fi

pip3 install ${PIP_FLAGS} -r "${OE_HOME_EXT}/requirements.txt"

REQ_EXTRAS="$(dirname "$(readlink -f "$0")")/requirements.txt"
if [ -f "${REQ_EXTRAS}" ]; then
  echo "    Extras desde ${REQ_EXTRAS}"
  pip3 install ${PIP_FLAGS} -r "${REQ_EXTRAS}"
else
  echo "    Extras inline (beautifulsoup4, numpy, xmltodict, pycountry) ..."
  pip3 install ${PIP_FLAGS} beautifulsoup4 numpy xmltodict pycountry
fi

say "9. Generando /etc/${OE_CONFIG}.conf ..."

ADDONS_PATH="${OE_HOME_EXT}/addons"

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

say "10. Creando directorio de logs ${LOG_DIR} ..."
mkdir -p "${LOG_DIR}"
chown "${OE_USER}:${OE_USER}" "${LOG_DIR}"

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
# Short-Description: Odoo Business Applications
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
