#!/bin/bash
# Healthcheck GLPI avec support flag et variable d'environnement
# Sortie 0 = healthy, 1 = unhealthy

FLAG_UPDATE="/var/www/glpi/config/glpi_updating"
FLAG_DISABLE="/var/www/glpi/config/glpi_disable_healthcheck"

# Si le flag de mise à jour existe, conteneur healthy
if [ -f "$FLAG_UPDATE" ]; then
    echo "[HEALTHCHECK] Mise à jour en cours → healthy"
    exit 0
fi

# Si le flag de désactivation existe, conteneur healthy
if [ -f "$FLAG_DISABLE" ]; then
    echo "[HEALTHCHECK] Healthcheck désactivé → healthy"
    exit 0
fi

# Vérifier la variable d'environnement DISABLE_HEALTHCHECK
if [ "${DISABLE_HEALTHCHECK:-0}" = "1" ]; then
    echo "[HEALTHCHECK] DISABLE_HEALTHCHECK=1 → healthy"
    exit 0
fi

# Vérification HTTP classique
URL="http://localhost/"
if curl -f -s "$URL" > /dev/null; then
    echo "[HEALTHCHECK] Serveur GLPI OK"
    exit 0
else
    echo "[HEALTHCHECK] Serveur GLPI non disponible !"
    exit 1
fi
