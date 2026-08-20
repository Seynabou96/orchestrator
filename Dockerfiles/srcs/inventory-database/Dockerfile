# =============================================================================
# inventory-database — PostgreSQL construit à la main (image officielle
# postgres: interdite par le sujet, sauf Alpine/Debian).
#
# Single-stage volontairement : il n'y a pas de phase de "compilation"
# distincte d'une phase d"exécution ici. apt-get install postgresql-15
# installe directement le binaire prêt à l'emploi — un split builder/
# runtime n'apporterait rien à copier d'un stage à l'autre (voir
# discussion architecture, même raisonnement pour billing-database et
# rabbitMQ).
#
# PostgreSQL 15 : version par défaut sur Debian 12 bookworm, disponible
# directement via apt sans dépôt PGDG supplémentaire.
#
# postgresql-contrib n'est PAS installé : il fournit des extensions
# optionnelles (uuid-ossp, pgcrypto, etc.) qu'on doit activer explicitement
# via CREATE EXTENSION pour s'en servir — ce projet n'en utilise aucune
# (le modèle Movie n'a que des colonnes Integer/String/Text standard).
# Ce paquet tire aussi perl comme dépendance transitive (via
# postgresql-client-common -> libipc-run-perl), qui n'apporte rien ici et
# n'est responsable que de CVE supplémentaires sans bénéfice réel.
# =============================================================================
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

ENV PG_VERSION=15 \
    PG_DATA=/var/lib/postgresql/data

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-${PG_VERSION} \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p ${PG_DATA} && \
    chown -R postgres:postgres ${PG_DATA} && \
    chmod 700 ${PG_DATA}

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER postgres

EXPOSE 5432

HEALTHCHECK --interval=5s --timeout=5s --retries=10 \
    CMD pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB} || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/lib/postgresql/15/bin/postgres", "-D", "/var/lib/postgresql/data"]
