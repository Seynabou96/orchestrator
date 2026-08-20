# =============================================================================
# Stage 1 — builder
#
# Même logique que inventory-app/Dockerfile : isoler l'outillage de
# compilation (gcc, libpq-dev) du stage final.
# =============================================================================
FROM debian:bookworm-slim AS builder

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-pip \
        gcc \
        libpq-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV VENV_PATH=/opt/venv
RUN python3 -m venv $VENV_PATH
ENV PATH="$VENV_PATH/bin:$PATH"

WORKDIR /build

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# =============================================================================
# Stage 2 — runtime
# =============================================================================
FROM debian:bookworm-slim AS runtime

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        libpq5 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV VENV_PATH=/opt/venv
ENV PATH="$VENV_PATH/bin:$PATH"

COPY --from=builder $VENV_PATH $VENV_PATH

WORKDIR /app

COPY . .

RUN groupadd -g 1000 billinguser && \
    useradd -u 1000 -g billinguser --create-home -s /bin/false billinguser && \
    chown -R billinguser:billinguser /app
USER billinguser

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=10s \
    CMD python3 -c "import urllib.request,sys,os; sys.exit(0 if urllib.request.urlopen('http://localhost:'+os.environ.get('BILLING_APP_PORT','8080')+'/health',timeout=3).status==200 else 1)" || exit 1

# --workers 1 (pas 4 comme inventory-app/api-gateway) : billing-app démarre
# un thread daemon consumer RabbitMQ au niveau module de server.py (voir ce
# fichier). Chaque worker gunicorn est un PROCESS séparé qui importerait le
# module indépendamment — avec plusieurs workers, on aurait plusieurs
# consumers concurrents sur la même queue. RabbitMQ gère ça nativement
# (distribution round-robin, pas de double traitement) donc ce ne serait
# pas un bug fonctionnel, mais c'est un gaspillage de ressources et une
# complexité inutile pour un service dont la seule route HTTP (/health)
# est extrêmement légère — un seul worker suffit largement.
CMD exec gunicorn --bind 0.0.0.0:${BILLING_APP_PORT:-8080} --workers 1 "server:app"
