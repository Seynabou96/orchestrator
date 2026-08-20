# =============================================================================
# Stage 1 — builder
#
# Rôle unique : installer les dépendances Python dans un venv isolé.
# gcc et libpq-dev sont nécessaires pour compiler certaines extensions C
# (psycopg2-binary embarque normalement des wheels précompilées, mais on
# garde l'outillage de compilation en filet de sécurité si jamais une wheel
# binaire n'existe pas pour l'architecture cible).
#
# Rien dans ce stage ne sera présent dans l'image finale, sauf ce qu'on
# copie explicitement avec --from=builder plus bas.
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
# Image finale, réellement déployée. Repart d'une base Debian bookworm
# propre — gcc, libpq-dev, python3-pip et tout l'outillage de build du
# stage précédent ne sont PAS présents ici. Seul le venv déjà construit
# est copié, avec les bibliothèques runtime strictement nécessaires
# (libpq5 — la librairie partagée client PostgreSQL, pas le paquet -dev
# qui contient les headers de compilation).
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

# Utilisateur non-root : limite l'impact si le conteneur est compromis.
# Nom spécifique au service (pas un générique "appuser" répété partout) :
# avec plusieurs conteneurs qui tournent, inspecter les process devient
# illisible si chacun s'appelle pareil — inventoryuser identifie sans
# ambiguïté à quel service ce process appartient.
# --create-home (pas -M) : certains outils Python (cache pip, configs
# diverses) s'attendent à un $HOME valide même en conteneur ; ne pas en
# créer un est une fausse optimisation qui peut casser silencieusement.
RUN groupadd -g 1000 inventoryuser && \
    useradd -u 1000 -g inventoryuser --create-home -s /bin/false inventoryuser && \
    chown -R inventoryuser:inventoryuser /app
USER inventoryuser

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=10s \
    CMD python3 -c "import urllib.request,sys,os; sys.exit(0 if urllib.request.urlopen('http://localhost:'+os.environ.get('INVENTORY_APP_PORT','8080')+'/health',timeout=3).status==200 else 1)" || exit 1

# gunicorn appelle directement la factory Flask via "app:create_app()" —
# pas de server.py exécuté comme script ici (app.run() reste pour le
# développement local hors conteneur, voir server.py).
#
# 'exec' est nécessaire ici : sans lui, /bin/sh resterait PID 1 et gunicorn
# tournerait comme processus enfant. docker stop envoie SIGTERM au PID 1
# uniquement — un /bin/sh qui ne relaie pas le signal forcerait Docker à
# attendre le timeout puis à envoyer SIGKILL, tuant gunicorn brutalement
# au lieu de lui laisser terminer proprement les requêtes en cours.
# 'exec' remplace le processus shell par gunicorn lui-même (même PID),
# qui reçoit alors directement SIGTERM et s'arrête proprement.
#
# Compromis assumé : `docker build` émet un avertissement
# "JSONArgsRecommended" sur cette ligne, car la forme JSON ["gunicorn",
# ...] est en général préférable pour la gestion des signaux. On ne peut
# pas l'utiliser ici : la forme JSON n'effectue AUCUNE substitution de
# variable d'environnement (${INVENTORY_APP_PORT} resterait une chaîne
# littérale, pas une valeur interprétée). La forme shell + exec règle le
# problème de signal que la forme JSON visait à éviter, donc ce warning
# est attendu et sans risque dans ce cas précis — pas un oubli.
CMD exec gunicorn --bind 0.0.0.0:${INVENTORY_APP_PORT:-8080} --workers 4 "app:create_app()"
