#!/bin/bash
set -e

# Export des variables d'environnement
export RABBITMQ_USER=${RABBITMQ_USER}
export RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}

# Démarrage de RabbitMQ en arrière-plan pour config initiale
rabbitmq-server -detached

# Attente active jusqu'à ce que RabbitMQ soit prêt
for i in {1..60}; do
    if rabbitmqctl status &>/dev/null; then
        echo "RabbitMQ est prêt."
        break
    fi
    sleep 1
done

# Création de l'utilisateur si nécessaire
if ! rabbitmqctl list_users | grep -q "^${RABBITMQ_USER}\b"; then
    echo "Création de l'utilisateur '${RABBITMQ_USER}'..."
    rabbitmqctl add_user "${RABBITMQ_USER}" "${RABBITMQ_PASSWORD}" || true
    rabbitmqctl set_user_tags "${RABBITMQ_USER}" administrator
    rabbitmqctl set_permissions -p / "${RABBITMQ_USER}" ".*" ".*" ".*"
    rabbitmqctl delete_user guest || true
fi

# Arrêt du serveur temporaire
rabbitmqctl stop

# Lancement final en avant-plan
exec rabbitmq-server
