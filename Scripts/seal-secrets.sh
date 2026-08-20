#!/bin/bash
# =============================================================================
# seal-secrets.sh — Génère les SealedSecret pour les 3 charts Helm
# (inventory, billing, api-gateway) à partir du certificat public
# Sealed Secrets.
#
# Pré-requis : ./Scripts/install-cluster-tools.sh a déjà tourné (kubeseal
# installé, certificat public récupéré dans ./.secrets-cert/).
#
# Usage :
#   ./seal-secrets.sh
# Le script demande chaque mot de passe de façon interactive (jamais en
# argument de ligne de commande, pour éviter qu'il finisse dans
# l'historique bash ou les logs).
#
# Les fichiers générés (charts/*/templates/sealed-*.yaml) SONT destinés
# à être committés sur GitHub — c'est tout le principe de Sealed
# Secrets : ils ne sont déchiffrables que par le contrôleur qui tourne
# dans CE cluster précis (clé privée jamais exportée).
# =============================================================================
set -euo pipefail

CERT_PATH="./.secrets-cert/pub-sealed-secrets.pem"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

if ! command -v kubeseal &> /dev/null; then
    log_error "kubeseal n'est pas installé. Lancez install-cluster-tools.sh d'abord."
    exit 1
fi

if [ ! -f "$CERT_PATH" ]; then
    log_error "Certificat public introuvable: $CERT_PATH"
    log_error "Lancez install-cluster-tools.sh d'abord."
    exit 1
fi

# Génère un mot de passe aléatoire de 24 caractères si l'utilisateur
# n'en fournit pas un manuellement (Entrée pour accepter la génération).
generate_password() {
    openssl rand -base64 18 | tr -d '=+/' | cut -c1-24
}

read_secret_value() {
    local prompt="$1"
    local default_user="$2"
    local value=""
    read -rp "$prompt (laisser vide pour générer un mot de passe aléatoire) : " value
    if [ -z "$value" ]; then
        value=$(generate_password)
        echo "  -> Mot de passe généré: $value" >&2
        echo "  -> NOTE-LE QUELQUE PART (gestionnaire de mots de passe), il ne sera plus affiché." >&2
    fi
    echo "$value"
}

seal_one_secret() {
    local namespace="$1"
    local secret_name="$2"
    local output_file="$3"
    shift 3
    # Le reste des arguments : paires clé=valeur
    local literals=()
    for kv in "$@"; do
        literals+=(--from-literal="$kv")
    done

    kubectl create secret generic "$secret_name" \
        --namespace="$namespace" \
        "${literals[@]}" \
        --dry-run=client -o yaml \
    | kubeseal \
        --cert="$CERT_PATH" \
        --format=yaml \
        > "$output_file"

    log_info "Généré: $output_file"
}

log_step "=== SCELLEMENT DES SECRETS — NAMESPACE inventory ==="
INVENTORY_DB_USER="inv_user"
INVENTORY_DB_PASSWORD=$(read_secret_value "Mot de passe inventory-database" "$INVENTORY_DB_USER")
seal_one_secret "inventory" "inventory-db-credentials" \
    "./charts/inventory/templates/sealed-inventory-db-credentials.yaml" \
    "INVENTORY_DB_USER=${INVENTORY_DB_USER}" \
    "INVENTORY_DB_PASSWORD=${INVENTORY_DB_PASSWORD}"

log_step "=== SCELLEMENT DES SECRETS — NAMESPACE billing ==="
BILLING_DB_USER="billing_user"
BILLING_DB_PASSWORD=$(read_secret_value "Mot de passe billing-database" "$BILLING_DB_USER")
seal_one_secret "billing" "billing-db-credentials" \
    "./charts/billing/templates/sealed-billing-db-credentials.yaml" \
    "BILLING_DB_USER=${BILLING_DB_USER}" \
    "BILLING_DB_PASSWORD=${BILLING_DB_PASSWORD}"

RABBITMQ_USER="mq_user"
RABBITMQ_PASSWORD=$(read_secret_value "Mot de passe rabbitmq" "$RABBITMQ_USER")
seal_one_secret "billing" "rabbitmq-credentials" \
    "./charts/billing/templates/sealed-rabbitmq-credentials.yaml" \
    "RABBITMQ_USER=${RABBITMQ_USER}" \
    "RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}"

log_step "=== SCELLEMENT DES SECRETS — NAMESPACE api-gateway ==="
# IMPORTANT : Sealed Secrets chiffre par COUPLE (namespace, nom) exact —
# c'est le scope "strict" par défaut. On ne peut PAS copier le fichier
# sealed-rabbitmq-credentials.yaml de billing/ vers api-gateway/ en
# éditant juste metadata.namespace à la main : le contrôleur refusera
# de le déchiffrer (chiffrement lié au namespace d'origine). Il faut un
# VRAI second appel à kubeseal, avec --namespace api-gateway, sur les
# MÊMES valeurs en clair — c'est ce que fait seal_one_secret ci-dessous,
# pas une copie de fichier.
#
# api-gateway a besoin des mêmes credentials RabbitMQ que billing-app
# car il publie sur la même queue (consommée ensuite par billing-app).
seal_one_secret "api-gateway" "rabbitmq-credentials" \
    "./charts/api-gateway/templates/sealed-rabbitmq-credentials.yaml" \
    "RABBITMQ_USER=${RABBITMQ_USER}" \
    "RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}"

echo ""
log_info "✅ 4 SealedSecret générés (inventory-db, billing-db, rabbitmq×2) :"
log_info "   charts/inventory/templates/sealed-inventory-db-credentials.yaml"
log_info "   charts/billing/templates/sealed-billing-db-credentials.yaml"
log_info "   charts/billing/templates/sealed-rabbitmq-credentials.yaml"
log_info "   charts/api-gateway/templates/sealed-rabbitmq-credentials.yaml"
log_info "Tous peuvent être committés sur GitHub sans risque."
