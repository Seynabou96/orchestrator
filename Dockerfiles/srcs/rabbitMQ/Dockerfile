FROM debian:bullseye-slim
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y rabbitmq-server && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Active le plugin de management (optionnel)
RUN rabbitmq-plugins enable rabbitmq_management

# Copie l'entrypoint (le vôtre actuel fonctionnera)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose uniquement le port AMQP 5672
EXPOSE 5672

ENTRYPOINT ["/entrypoint.sh"]

