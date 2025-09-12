FROM debian:bullseye-slim

ARG DEBIAN_FRONTEND=noninteractive 
ENV PG_VERSION=13 \
    PG_DATA=/var/lib/postgresql/data

# Installation de PostgreSQL
RUN apt-get update && \
    apt-get install -y --no-install-recommends\
    postgresql-${PG_VERSION} \
    postgresql-contrib-${PG_VERSION} \
    && apt-get clean \
    &&  rm -rf /var/lib/apt/lists/*

# Configuration des permissions
RUN mkdir -p ${PG_DATA} && \
    chown -R postgres:postgres ${PG_DATA} && \
    chmod 700 ${PG_DATA}

# Initialisation conditionnelle
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER postgres


EXPOSE 5432

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/lib/postgresql/13/bin/postgres", "-D", "/var/lib/postgresql/data"]