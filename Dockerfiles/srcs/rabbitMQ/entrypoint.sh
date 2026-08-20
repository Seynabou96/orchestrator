#!/bin/bash
# =============================================================================
# Entrypoint rabbitMQ — initialisation idempotente de l'utilisateur applicatif.
#
# set -e : toute commande qui échoue arrête le script immédiatement, sauf
# là où on neutralise volontairement ce comportement (voir plus bas).
#
# Correction par rapport à l'entrypoint précédent : l'ancien testait
# l'existence de l'utilisateur via "list_users | grep -q ..." AVANT de le
# créer. Ce pattern s'est révélé fragile sur CRUD Master (faux positif
# observé : "déjà présent" alors que rabbitmqctl set_user_tags échouait
# juste après avec {:no_such_user, ...}). On applique ici la même
# discipline qui a corrigé ce bug : tenter la création, ignorer
# uniquement l'erreur "déjà existant", remonter toute autre vraie erreur,
# puis VÉRIFIER l'état réel avant de continuer — jamais supposer.
# =============================================================================
set -e

echo ">>> [rabbitMQ] Démarrage du serveur en arrière-plan pour configuration initiale"
rabbitmq-server -detached

echo ">>> [rabbitMQ] Attente de la disponibilité du broker..."
# IMPORTANT : 'rabbitmq-diagnostics ping' vérifie seulement que le runtime
# Erlang répond — PAS que l'application 'rabbit' elle-même est chargée et
# prête à traiter des commandes de gestion (add_user, etc.). Bug constaté
# en pratique : ping réussissait pendant que add_user échouait encore
# avec "this command requires the 'rabbit' app to be running". La
# documentation officielle RabbitMQ confirme cette distinction explicite :
# check_running échoue "if the RabbitMQ application is not running on the
# target node", alors que ping se contente d'un runtime actif. On utilise
# donc check_running ici, qui est le signal correct avant tout add_user.
for i in $(seq 1 30); do
    if rabbitmq-diagnostics -q check_running > /dev/null 2>&1; then
        echo ">>> [rabbitMQ] Application 'rabbit' prête (tentative $i)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo ">>> [rabbitMQ] ERREUR : l'application 'rabbit' n'a jamais démarré" >&2
        exit 1
    fi
    sleep 1
done

echo ">>> [rabbitMQ] Création/vérification de l'utilisateur '${RABBITMQ_USER}'"
ADD_USER_OUTPUT=$(rabbitmqctl add_user "${RABBITMQ_USER}" "${RABBITMQ_PASSWORD}" 2>&1) || true
echo "$ADD_USER_OUTPUT"
if echo "$ADD_USER_OUTPUT" | grep -qi "error" && ! echo "$ADD_USER_OUTPUT" | grep -qi "already_exists"; then
    echo ">>> [rabbitMQ] ERREUR inattendue lors de la création de l'utilisateur" >&2
    exit 1
fi

# Vérification réelle de l'existence, plutôt que de supposer que
# add_user a réussi silencieusement.
if ! rabbitmqctl list_users | awk -F'\t' '{print $1}' | grep -qx "${RABBITMQ_USER}"; then
    echo ">>> [rabbitMQ] ERREUR : l'utilisateur '${RABBITMQ_USER}' n'a pas pu être créé ou détecté" >&2
    rabbitmqctl list_users
    exit 1
fi

rabbitmqctl set_user_tags "${RABBITMQ_USER}" administrator
rabbitmqctl set_permissions -p / "${RABBITMQ_USER}" ".*" ".*" ".*"

# Suppression de l'utilisateur 'guest' par défaut (credentials publiquement
# connus, RabbitMQ refuse même les connexions guest depuis l'extérieur de
# localhost par défaut — mais le supprimer reste la pratique la plus sûre
# plutôt que de compter sur cette restriction réseau implicite).
rabbitmqctl delete_user guest 2>/dev/null || true

echo ">>> [rabbitMQ] Configuration terminée, arrêt du serveur temporaire"
rabbitmqctl stop

echo ">>> [rabbitMQ] Lancement final en avant-plan"
exec rabbitmq-server
