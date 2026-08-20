# =============================================================================
# billing-database — PostgreSQL construit à la main, même logique que
# inventory-database (voir ce Dockerfile pour le raisonnement détaillé
# sur single-stage et le retrait de postgresql-contrib).
#
# Single-stage volontairement : apt-get install postgresql-15 installe
# un binaire prêt à l'emploi, pas de phase de compilation à séparer
# d'une phase d'exécution.
#
# postgresql-contrib n'est PAS installé : extensions optionnelles non
# utilisées par ce projet (table orders = colonnes String standard),
# et ce paquet tire perl en dépendance transitive sans bénéfice réel
# (source de CVE non actionnables constatées sur inventory-database).
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
