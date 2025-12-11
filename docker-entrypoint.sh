#!/bin/bash
set -e

if echo "$@" | grep -q "cron.php"; then
    echo "[INFO] Running in CRON mode → skipping GLPI installation & permissions."
    echo "[INFO] Pause cron job during 60s ..."
    sleep 60
    exec "$@"
    exit 0
fi

echo "=============================================================================="
echo ""
echo "[INFO] Version d Apache2 : "
su -s /bin/bash www-data -c "apache2 -v"
echo ""
echo "[INFO] Version de PHP : "
su -s /bin/bash www-data -c "php -v"
echo ""
echo "=============================================================================="

echo "🔍 Verification des variables d environnement..."

REQUIRED_VARS=(
  GLPI_DOMAIN  
  GLPI_DB_HOST
  GLPI_DB_NAME
  GLPI_DB_USER
  GLPI_DB_PASSWORD
)

for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    echo "❌ Variable obligatoire manquante : $VAR"
    EXIT=1
  else
    echo "✔️  $VAR : ${!VAR}"
  fi
done

if [ "$EXIT" = 1 ]; then
  echo "⛔ Fin du script : certaines variables ne sont pas definies."
  exit 1
fi
echo "✅ Variables obligatoire OK"

GITHUB_API="https://api.github.com/repos/glpi-project/glpi/releases/latest" # URI API GITHUB POUR RECUPERER LA DERNIERE VERSION DE GLPI DISPINIBLE
URI_FALLBACK="${URI_FALLBACK:-https://github.com/glpi-project/glpi/releases/download/11.0.3/glpi-11.0.3.tgz}"

APACHE_CONF="/etc/apache2/sites-available/glpi.conf"
PHP_CONF_FILE="/etc/php/8.3/fpm/conf.d/90-glpi.ini"
GLPI_DIR="/var/www/glpi"
GLPI_CONFIG_FILE="/var/www/glpi/config/config_db.php"
GLPI_UPDATING="/var/www/glpi/config/glpi_updating"

echo "🔧 Application des variables optionnelles..."

# Variables optionnelle
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-512M}"
PHP_UPLOAD_MAX_FILESIZE="${PHP_UPLOAD_MAX_FILESIZE:-50M}"
PHP_MAX_EXECUTION_TIME="${PHP_MAX_EXECUTION_TIME:-300}"
GLPI_VERSION_INSTALL="${GLPI_VERSION_INSTALL:-}"
GLPI_TIMEZONE="${GLPI_TIMEZONE:-Europe/Paris}"
GLPI_UPDATE_DB="${GLPI_UPDATE_DB:-No}"
GLPI_CHECK_REQUIREMENT="${GLPI_CHECK_REQUIREMENT:-No}"
GLPI_REDIS_ENABLE="${GLPI_REDIS_ENABLE:-No}"
GLPI_REDIS_SERVER="${GLPI_REDIS_SERVER:-glpi-redis}"
GLPI_TIMEZONE_CONFIG="${GLPI_TIMEZONE_CONFIG:-Yes}"
GLPI_DISABLE_MAINTENANCE="${GLPI_DISABLE_MAINTENANCE:-No}"
# URI
GLPI_HTTP_PROTOCOLE="${GLPI_HTTP_PROTOCOLE:-http}"
GLPI_FORCE_APPLY_URI="${GLPI_FORCE_APPLY_URI:-No}"
# HEALTHCHECK
HEALTHCHECK_DISABLE="${HEALTHCHECK_DISABLE:-No}"

echo "✔️  PHP_MEMORY_LIMIT = $PHP_MEMORY_LIMIT"
echo "✔️  PHP_UPLOAD_MAX_FILESIZE = $PHP_UPLOAD_MAX_FILESIZE"
echo "✔️  PHP_MAX_EXECUTION_TIME = $PHP_MAX_EXECUTION_TIME"
echo "     URI_FALLBACK = $URI_FALLBACK "

if [ -f "$GLPI_UPDATING" ]; then
    echo " 🔄 GLPI est en cours de mise a jour ..."
    echo " Healthcheck desactive"
    $GLPI_UPDATE_DB="Yes"
    $GLPI_DISABLE_MAINTENANCE="Yes"
fi

rm -f /var/www/glpi/config/glpi_disable_healthcheck
if [ "${HEALTHCHECK_DISABLE}" = "Yes" ]; then
    echo ""
    echo "[INFO] Desactivation du healthcheck"
    touch /var/www/glpi/config/glpi_disable_healthcheck
fi


echo "[INFO] Configuration du virtualhost Apache avec le domaine : ${GLPI_DOMAIN}"
tee ${APACHE_CONF} > /dev/null <<EOF
<VirtualHost *:80>
    ServerName ${GLPI_DOMAIN}
    DocumentRoot ${GLPI_DIR}/public

    ErrorLog /var/log/apache2/error.log
    CustomLog /var/log/apache2/access.log combined

    <Directory ${GLPI_DIR}/public>
        AllowOverride All
        Require all granted
        RewriteEngine On
        RewriteCond %{HTTP:Authorization} ^(.+)$
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>
</VirtualHost>
EOF
a2ensite glpi

echo "[INFO] Configuration PHP pour GLPI"
tee "${PHP_CONF_FILE}" > /dev/null <<EOF
; Configuration PHP specifique a GLPI
; Appliquee uniquement au repertoire : ${GLPI_DIR}

[PATH=${GLPI_DIR}]
memory_limit = ${PHP_MEMORY_LIMIT}
upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}
post_max_size = ${PHP_UPLOAD_MAX_FILESIZE}
max_execution_time = ${PHP_MAX_EXECUTION_TIME}
max_input_vars = 5000
date.timezone = "${GLPI_TIMEZONE}"
;session.cookie_secure = 1
;session.cookie_httponly = 1
EOF

CLI_CONF="/etc/php/8.3/cli/conf.d/90-glpi.ini"
if [ ! -f "${PHP_CONF_FILE}" ]; then
  ln -s "${PHP_CONF_FILE}" "${CLI_CONF}"
fi

# MariaDB - Timezone
if [ "$GLPI_TIMEZONE_CONFIG" = "Yes" ]; then
    echo "[INFO] Ajout des droits a utilisateur ${GLPI_DB_USER} dans la base de donnees sur les timezones."
    HAS_PRIV=$(mariadb -h "$GLPI_DB_HOST" -u "root" -p"$MYSQL_ROOT_PASSWORD" \
            -N -e "SELECT COUNT(*) FROM mysql.tables_priv WHERE User='$GLPI_DB_USER' AND Db='mysql' AND Table_name='time_zone_name';")
        
    if [ "$HAS_PRIV" -eq 0 ]; then
        echo "[INFO] Applying SQL privilege for $GLPI_DB_USER ... ✅"
        mariadb -h "$GLPI_DB_HOST" -u "root" -p"$MYSQL_ROOT_PASSWORD" -e \
            "GRANT SELECT ON mysql.time_zone_name TO '$GLPI_DB_USER'@'%'; FLUSH PRIVILEGES;"
    else
        echo "[INFO] SQL privilege already present. Skipping."
    fi
fi

echo "Verification si GLPI est deja installe."
if [ -f "$GLPI_CONFIG_FILE" ]; then
    echo "GLPI est present"
    GLPI_CONFIG_FILE_EXISTE=1
else
    echo "GLPI non installe"
    GLPI_CONFIG_FILE_EXISTE=0
fi

if [ "$GLPI_CONFIG_FILE_EXISTE" -eq 0 ]; then

    # URI de telechargement
    if [ "$GLPI_VERSION_INSTALL" = "" ]; then
        GLPI_URI_LAST=$(curl -s --max-time 10 ${GITHUB_API} \
          | grep "browser_download_url" \
          | grep -E "\.tgz" \
          | cut -d '"' -f 4 || true)

        if [[ -z "${GLPI_URI_LAST}" ]]; then
            echo "[INFO] Impossible de trouver la dernier version sur Github, utilisation de URL de fallback : ${URI_FALLBACK}"
            GLPI_DOWNLOAD_URI=$URI_FALLBACK
        else
            echo "[INFO] URL de telelchargement de la derniere version sur Github : ${GLPI_URI_LAST}"
            GLPI_DOWNLOAD_URI=$GLPI_URI_LAST
        fi
    else
        # URI base sur la version passee en parametre
        GLPI_DOWNLOAD_URI="https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION_INSTALL}/glpi-${GLPI_VERSION_INSTALL}.tgz"
        echo "[INFO] Version d installation de GLPI passe en parametre : ${GLPI_VERSION_INSTALL}, URI de telechargement utilisee : ${GLPI_DOWNLOAD_URI}"
    fi    
    
    echo "[INFO] Telechargement de GLPI depuis l URL : ${GLPI_DOWNLOAD_URI}"
    if ! curl -sL "${GLPI_DOWNLOAD_URI}" | tar -xzf - -C /tmp; then
        echo "❌ Telechargement automatique echoue, utilisation du fallback..."
        if ! curl -sL "${URI_FALLBACK}" | tar -xzf - -C /tmp; then
            echo "⛔  Impossible de telechargement archige de GLPI depuis l URI de Fallblach (${URI_FALLBACK})"
            exit 2
        fi
    fi

    echo "Deplacement des fichiers de GLPI dans le dossier : ${GLPI_DIR}"
    mv /tmp/glpi/* "${GLPI_DIR}"

    echo "Creation du fichier de configuration de base de donnee"

    tee /var/www/glpi/config/config_db.php > /dev/null <<EOF
<?php
class DB extends DBmysql {
   public \$dbhost = '$GLPI_DB_HOST';
   public \$dbuser = '$GLPI_DB_USER';
   public \$dbpassword = '$GLPI_DB_PASSWORD';
   public \$dbdefault = '$GLPI_DB_NAME';
   public \$use_utf8mb4 = true;
   public \$allow_datetime = false;
   public \$allow_signed_keys = false;
   public \$use_timezones = true;
}
EOF

    echo "Modification des droits sur le repertoire ..."
    chown -R www-data:www-data "${GLPI_DIR}"

    echo "Installation automatique de GLPI"
    cd ${GLPI_DIR}
    su -s /bin/bash www-data -c "php bin/console db:install --force --no-telemetry --no-interaction"
    su -s /bin/bash www-data -c "php bin/console config:set url_base ${GLPI_HTTP_PROTOCOLE}://${GLPI_DOMAIN}"
fi

echo "[INFO] Verification si une mise a jour disponibe"

VERSION_FILE="$GLPI_DIR/src/autoload/constants.php"

if [ ! -f "$VERSION_FILE" ]; then
    echo "❌ Erreur : fichier $VERSION_FILE introuvable"
    exit 3
fi

INSTALLED_VERSION=$(grep -oP "GLPI_VERSION', '\K\d+\.\d+\.\d+(-\w+)?" "$VERSION_FILE")

if [ -z "$INSTALLED_VERSION" ]; then
    echo "❌ Impossible de determiner la version installee"
fi

LATEST_VERSION=$(curl -s "$GITHUB_API" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//')

if [ -z "$LATEST_VERSION" ]; then
    echo "❌ Impossible de recuperer la derniere version disponible"
fi

echo "[INFO] Version installee : $INSTALLED_VERSION"
echo "[INFO] Derniere version disponible : $LATEST_VERSION"

INSTALLED_NUM=$(echo "$INSTALLED_VERSION" | awk -F. '{ printf("%d%03d%03d\n",$1,$2,$3); }')
LATEST_NUM=$(echo "$LATEST_VERSION" | awk -F. '{ printf("%d%03d%03d\n",$1,$2,$3); }')

if [ "$LATEST_NUM" -gt "$INSTALLED_NUM" ]; then
    echo "🔔  Mise a jour disponible : $LATEST_VERSION"
else
    echo "✅  GLPI est deja a jour"
fi

# Application des droits sur le dossier
echo "[INFO] Verification des droits sur le dossier ${GLPI_DIR} ..."
echo "[CMD] chown -R www-data:www-data ${GLPI_DIR}"
cd ${GLPI_DIR}
chown -R www-data:www-data "${GLPI_DIR}"


if [ "${GLPI_CHECK_REQUIREMENT}" = "Yes" ]; then 
    echo "[INFO] Verification des prequis"
    echo "[CMD] su -s /bin/bash www-data -c \"php bin/console glpi:system:check_requirements\""
    cd ${GLPI_DIR}
    su -s /bin/bash www-data -c "php bin/console glpi:system:check_requirements"
fi

if [ "$GLPI_UPDATE_DB" = "Yes" ]; then
    # Maj base de donnee si upgrade des fichiers.
    echo "[INFO] Mise a jour de la base de donnee GLPI ..."
    cd ${GLPI_DIR}
    echo "[CMD] su -s /bin/bash www-data -c \"php bin/console db:update --force --no-telemetry --no-interaction\""
    su -s /bin/bash www-data -c "php bin/console db:update --force --no-telemetry --no-interaction"
fi

if [ "$GLPI_DISABLE_MAINTENANCE" = "Yes" ]; then
    # On sort GLPI du mode maintenance.
    echo "[INFO] Sortie du mode maintenance ..."
    cd ${GLPI_DIR}
    echo "[CMD] su -s /bin/bash www-data -c \"php bin/console glpi:maintenance:disable\""
    su -s /bin/bash www-data -c "php bin/console glpi:maintenance:disable"
fi

if [ "$GLPI_FORCE_APPLY_URI" = "Yes" ]; then
    # Configuration URI GLPI
    echo "[INFO] Configuration de URL de GLPI : ${GLPI_HTTP_PROTOCOLE}://${GLPI_DOMAIN}"
    cd ${GLPI_DIR}
    echo "[INFO] su -s /bin/bash www-data -c \"php bin/console config:set url_base ${GLPI_HTTP_PROTOCOLE}://${GLPI_DOMAIN}\""
    su -s /bin/bash www-data -c "php bin/console config:set url_base ${GLPI_HTTP_PROTOCOLE}://${GLPI_DOMAIN}"
fi 

if [ "$GLPI_REDIS_ENABLE" = "Yes" ]; then
    echo "[INFO] Configuration de Redis pour GLPI"
    cd ${GLPI_DIR}
    echo "[CMD] su -s /bin/bash www-data -c \"php bin/console cache:configure --context core --dsn redis://${GLPI_REDIS_SERVER}:6379/1 || true\""
    su -s /bin/bash www-data -c "php bin/console cache:configure --context core --dsn redis://${GLPI_REDIS_SERVER}:6379/1 || true"
else
    cd ${GLPI_DIR}
    echo "[INFO] Configuration : desactivation de Redis pour GLPI"
    echo "[CMD] su -s /bin/bash www-data -c \"php bin/console cache:configure --context core --use-default|| false\""
    su -s /bin/bash www-data -c "php bin/console cache:configure --context core --use-default || false"
fi

if [ "${GLPI_TIMEZONE_CONFIG}" = "Yes" ]; then
    echo "[INFO] GLPI Timezone Database enable"
    echo "[CMD] su -s /bin/bash www-data -c \"php bin/console database:enable_timezones\""
    cd ${GLPI_DIR}
    su -s /bin/bash www-data -c "php bin/console database:enable_timezones"
fi

echo "🚀 Demarrage du conteneur..."
exec "$@"