#!/bin/bash
# =============================================================================
# build-and-push-images.sh — Build des 6 images et push vers Docker Hub
# (sniang96), tag 1.0.0.
#
# Source de vérité : le code et les Dockerfiles, DÉJÀ VALIDÉS dans le
# projet play-with-containers, ne sont pas modifiés par ce script. Une
# copie à jour vit dans ./Dockerfiles (pour que ce repo soit autonome) ;
# le script peut aussi être pointé vers un autre chemin (ex: un clone
# séparé de play-with-containers) si besoin de rebuilder depuis une
# version plus récente avant qu'elle soit resynchronisée ici.
#
# Pré-requis : docker installé et `docker login` déjà fait (ou le script
# le déclenchera si besoin).
#
# Usage :
#   ./build-and-push-images.sh ./Dockerfiles
#   ./build-and-push-images.sh /chemin/vers/play-with-containers
# =============================================================================
set -euo pipefail

DOCKERHUB_USER="sniang96"
TAG="1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

PWC_DIR="${1:-}"
if [ -z "$PWC_DIR" ] || [ ! -d "$PWC_DIR/srcs" ]; then
    log_error "Usage: $0 <chemin-vers-dossier-contenant-srcs/>"
    log_error "Ex: $0 ./Dockerfiles  (ou un chemin vers play-with-containers)"
    log_error "Le dossier fourni doit contenir un sous-dossier srcs/"
    exit 1
fi

# Mapping nom-repo-dockerhub -> sous-dossier source. Les noms à gauche
# correspondent aux repos DÉJÀ EXISTANTS sur sniang96 (Docker Hub) —
# rabbitmq, billing-database, inventory-database, api-gateway-app ont
# 9-10 mois d'historique ; ne pas les renommer sous peine de créer des
# repos en double (ce qui s'est produit une première fois avec
# billing-db/inventory-db avant cette correction).
declare -A IMAGES=(
    ["inventory-database"]="inventory-database"
    ["billing-database"]="billing-database"
    ["rabbitmq"]="rabbitMQ"
    ["inventory-app"]="inventory-app"
    ["billing-app"]="billing-app"
    ["api-gateway-app"]="api-gateway"
)

if ! command -v docker &> /dev/null; then
    log_error "Docker n'est pas installé ou pas dans le PATH"
    exit 1
fi

log_step "=== VÉRIFICATION DE LA SESSION DOCKER HUB ==="
if ! docker info 2>/dev/null | grep -q "Username: $DOCKERHUB_USER"; then
    log_info "Connexion à Docker Hub requise pour $DOCKERHUB_USER..."
    docker login --username "$DOCKERHUB_USER"
fi

log_step "=== BUILD DES 6 IMAGES (depuis $PWC_DIR/srcs) ==="
for local_name in "${!IMAGES[@]}"; do
    src_dir="${IMAGES[$local_name]}"
    full_path="$PWC_DIR/srcs/$src_dir"

    if [ ! -f "$full_path/Dockerfile" ]; then
        log_error "Dockerfile introuvable: $full_path/Dockerfile"
        exit 1
    fi

    log_info "Build $local_name (depuis srcs/$src_dir)..."
    docker build --no-cache -t "$local_name:$TAG" "$full_path"
done

log_step "=== TAG VERS $DOCKERHUB_USER ==="
for local_name in "${!IMAGES[@]}"; do
    remote_name="$DOCKERHUB_USER/$local_name:$TAG"
    log_info "Tag $local_name:$TAG -> $remote_name"
    docker tag "$local_name:$TAG" "$remote_name"
done

log_step "=== PUSH VERS DOCKER HUB ==="
for local_name in "${!IMAGES[@]}"; do
    remote_name="$DOCKERHUB_USER/$local_name:$TAG"
    log_info "Push $remote_name..."
    docker push "$remote_name"
done

echo ""
log_info "✅ Les 6 images sont poussées sur Docker Hub :"
for local_name in "${!IMAGES[@]}"; do
    echo "   - $DOCKERHUB_USER/$local_name:$TAG"
done
echo ""
log_info "Vérifie sur https://hub.docker.com/u/$DOCKERHUB_USER"
