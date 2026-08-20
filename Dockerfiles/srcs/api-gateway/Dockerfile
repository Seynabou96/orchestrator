# =============================================================================
# Stage 1 — builder
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
#
# La gateway est stateless : pas de base de données, pas de thread daemon
# (contrairement à billing-app). Plusieurs workers gunicorn sont donc sans
# risque ici, chaque requête HTTP est indépendante des autres.
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

# /app/logs créé explicitement ICI, avant le chown global et avant le
# montage du volume Compose (api-gateway-app:/app/logs). Sans cette
# création explicite, Docker créerait le point de montage avec root
# comme propriétaire au démarrage du conteneur, et gatewayuser (non-root)
# n'aurait pas le droit d'écrire dedans — le logging.FileHandler vers
# ce chemin échouerait silencieusement avec une PermissionError.
RUN mkdir -p /app/logs && \
    groupadd -g 1000 gatewayuser && \
    useradd -u 1000 -g gatewayuser --create-home -s /bin/false gatewayuser && \
    chown -R gatewayuser:gatewayuser /app
USER gatewayuser

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=10s \
    CMD python3 -c "import urllib.request,sys,os; sys.exit(0 if urllib.request.urlopen('http://localhost:'+os.environ.get('GATEWAY_APP_PORT','3000')+'/health',timeout=3).status==200 else 1)" || exit 1

CMD exec gunicorn --bind 0.0.0.0:${GATEWAY_APP_PORT:-3000} --workers 4 "app:create_app()"
