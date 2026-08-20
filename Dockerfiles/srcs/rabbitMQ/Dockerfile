# =============================================================================
# rabbitMQ — broker construit à la main (image officielle rabbitmq:
# interdite par le sujet, sauf Alpine/Debian).
#
# Single-stage : même raisonnement que les Dockerfiles PostgreSQL — pas
# de phase de compilation séparée d'une phase d'exécution, apt-get install
# installe directement le binaire prêt à l'emploi.
#
# Le paquet Debian rabbitmq-server crée déjà un utilisateur système non
# privilégié 'rabbitmq' (documentation officielle RabbitMQ : "It will run
# as a non-privileged user rabbitmq"). Pas besoin de créer un utilisateur
# custom — on réutilise celui déjà fourni par le paquet, même principe
# que USER postgres pour les Dockerfiles PostgreSQL.
# =============================================================================
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        rabbitmq-server \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Plugin de management : interface web de diagnostic (queues, connexions,
# messages en attente). Utile en développement pour visualiser l'état
# réel du broker sans CLI — voir README pour l'accès.
RUN rabbitmq-plugins enable --offline rabbitmq_management

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && \
    chown rabbitmq:rabbitmq /entrypoint.sh

USER rabbitmq

# 5672 : port AMQP, utilisé par billing-app et api-gateway pour publier/
#   consommer des messages.
# 15672 : port HTTP de l'interface de management. Exposé en cohérence
#   avec le plugin activé ci-dessus — l'ancien Dockerfile activait le
#   plugin sans jamais documenter ni exposer son port, incohérence
#   corrigée ici.
EXPOSE 5672 15672

# check_running, pas ping : ping ne vérifie que le runtime Erlang, pas
# que l'application 'rabbit' elle-même est chargée et prête à servir des
# connexions. Bug réel rencontré avec ping (HEALTHCHECK marquait le
# conteneur "healthy" alors que rabbitmqctl add_user échouait encore
# dans l'entrypoint) — voir entrypoint.sh pour le détail. check_local_alarms
# délibérément pas ajouté en complément : la doc RabbitMQ signale des
# faux positifs sous charge mémoire avec ce check, sans bénéfice clair
# pour notre cas d'usage simple (un seul nœud, pas de cluster).
HEALTHCHECK --interval=10s --timeout=5s --retries=10 --start-period=15s \
    CMD rabbitmq-diagnostics -q check_running || exit 1

ENTRYPOINT ["/entrypoint.sh"]
