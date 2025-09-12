#!/bin/bash
set -e

if [ -z "$(ls -A ${PG_DATA})" ]; then
    # Initialisation de la base
    /usr/lib/postgresql/${PG_VERSION}/bin/initdb -D ${PG_DATA}
    
    # Configuration réseau
    echo "host all all all md5" >> ${PG_DATA}/pg_hba.conf
    echo "listen_addresses = '*'" >> ${PG_DATA}/postgresql.conf
    
    # Démarrage temporaire
    /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl -D ${PG_DATA} -o "-c listen_addresses='*'" -w start
    
    # Création utilisateur et DB avec tous les privilèges
    psql -v ON_ERROR_STOP=1 --username postgres <<EOSQL
        CREATE USER "${POSTGRES_USER}" WITH PASSWORD '${POSTGRES_PASSWORD}';
        CREATE DATABASE "${POSTGRES_DB}" OWNER "${POSTGRES_USER}";
        GRANT ALL PRIVILEGES ON DATABASE "${POSTGRES_DB}" TO "${POSTGRES_USER}";
        
        \c "${POSTGRES_DB}"
        GRANT ALL ON SCHEMA public TO "${POSTGRES_USER}";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "${POSTGRES_USER}";
EOSQL
    
    # Arrêt propre
    /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl -D ${PG_DATA} -m fast -w stop
fi

exec "$@"