FROM debian:bullseye-slim


# Variables purement pour le build (si besoin)
ARG DEBIAN_FRONTEND=noninteractive

# Installation optimisée des dépendances système

RUN apt-get update && \
apt-get install -y --no-install-recommends \
python3 \
python3-pip \
python3-venv \
libpq-dev \
gcc \
&& apt-get clean \
&& rm -rf /var/lib/apt/lists/* /tmp/*

# 2. Créer et activer un environnement virtuel
ENV VENV_PATH=/opt/venv
RUN python3 -m venv $VENV_PATH
ENV PATH="$VENV_PATH/bin:$PATH"    
# Configuration du workspace
WORKDIR /usr/src/

# Installation des dépendances Python
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# Copie de l'application
COPY . .

# Commande de démarrage
CMD ["python3", "./app/server.py"]