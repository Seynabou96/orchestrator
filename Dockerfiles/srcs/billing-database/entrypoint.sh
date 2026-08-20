#!/bin/bash
# =============================================================================
# Entrypoint billing-database — initialisation idempotente.
#
# set -e : toute commande qui échoue arrête le script immédiatement.
# Ajout par rapport à la version précédente : chaque étape SQL critique
# est explicitement vérifiée plutôt que supposée réussie — un échec de
# CREATE USER (ex: volume partiellement initialisé après un crash) ne
# doit jamais laisser le conteneur démarrer dans un état incohérent où
# l'application croit avoir une base prête alors qu'elle ne l'est pas.
# =============================================================================
set -e

if [ -z "$(ls -A ${PG_DATA} 2>/dev/null)" ]; then
    echo ">>> [billing-database] Premier démarrage — initialisation de la base"

    /usr/lib/postgresql/${PG_VERSION}/bin/initdb --locale=C.UTF-8 --encoding=UTF8 -D ${PG_DATA}

    echo "host all all all md5" >> ${PG_DATA}/pg_hba.conf
    echo "listen_addresses = '*'" >> ${PG_DATA}/postgresql.conf

    /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl -D ${PG_DATA} \
        -o "-c listen_addresses='*'" -w start

    # ON_ERROR_STOP=1 : psql s'arrête à la première erreur SQL plutôt que
    # de continuer en ignorant l'échec — sans ça, un CREATE USER raté
    # laisserait le script continuer comme si tout allait bien.
    if ! psql -v ON_ERROR_STOP=1 --username postgres <<EOSQL
        CREATE USER "${POSTGRES_USER}" WITH PASSWORD '${POSTGRES_PASSWORD}';
        CREATE DATABASE "${POSTGRES_DB}" OWNER "${POSTGRES_USER}";
        GRANT ALL PRIVILEGES ON DATABASE "${POSTGRES_DB}" TO "${POSTGRES_USER}";

        \c "${POSTGRES_DB}"
        GRANT ALL ON SCHEMA public TO "${POSTGRES_USER}";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "${POSTGRES_USER}";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "${POSTGRES_USER}";
EOSQL
    then
        echo ">>> [billing-database] ERREUR : l'initialisation SQL a échoué" >&2
        /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl -D ${PG_DATA} -m fast -w stop || true
        exit 1
    fi

    echo ">>> [billing-database] Initialisation réussie"
    /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl -D ${PG_DATA} -m fast -w stop
else
    echo ">>> [billing-database] Volume déjà initialisé, démarrage direct"
fi

exec "$@"
