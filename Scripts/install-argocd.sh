#!/bin/bash
# =============================================================================
# install-argocd.sh — Installe ArgoCD v3.4.4 + CLI + ApplicationSet
#
# Version : 3.4.4 (stable, 18 juin 2026 — dernière version vérifiée)
# Flag --server-side --force-conflicts : obligatoire depuis v3.x car
# certains CRDs dépassent la limite d'annotation client-side (262 Ko).
# Sans ce flag, kubectl apply échoue silencieusement sur ces CRDs.
#
# Pré-requis : make create déjà exécuté (cluster K3s + Cilium actifs),
# kubectl configuré sur l'hôte.
# =============================================================================
set -euo pipefail

ARGOCD_VERSION="v3.4.4"
ARGOCD_NAMESPACE="argocd"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -----------------------------------------------------------------------------
# 1. Installation d'ArgoCD
# -----------------------------------------------------------------------------
log_step "=== INSTALLATION D'ARGOCD ${ARGOCD_VERSION} ==="
kubectl create namespace "${ARGOCD_NAMESPACE}" 2>/dev/null || true

kubectl apply \
    --namespace "${ARGOCD_NAMESPACE}" \
    --server-side \
    --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

log_info "Attente que ArgoCD soit prêt (peut prendre 2-3 minutes)..."
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-server --timeout=300s
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-applicationset-controller --timeout=300s

# -----------------------------------------------------------------------------
# 2. Installation du CLI ArgoCD
# -----------------------------------------------------------------------------
log_step "=== INSTALLATION DU CLI ARGOCD ==="
if command -v argocd &>/dev/null; then
    log_info "argocd CLI déjà installé ($(argocd version --client --short 2>/dev/null || true))"
else
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) log_error "Architecture non gérée: $ARCH"; exit 1 ;;
    esac
    log_info "Téléchargement du CLI ArgoCD ${ARGOCD_VERSION} (${ARCH})..."
    curl -sSL -o /tmp/argocd \
        "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARCH}"
    sudo install -m 755 /tmp/argocd /usr/local/bin/argocd
    rm -f /tmp/argocd
    log_info "CLI installé : $(argocd version --client --short 2>/dev/null || true)"
fi

# -----------------------------------------------------------------------------
# 3. Récupération du mot de passe admin initial
# -----------------------------------------------------------------------------
log_step "=== MOT DE PASSE ADMIN INITIAL ==="
log_info "Attente de la création du secret admin-password..."
timeout=60
counter=0
until kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret &>/dev/null; do
    if [ $counter -gt $timeout ]; then
        log_error "Secret admin-password non créé après ${timeout}s"
        exit 1
    fi
    sleep 3
    counter=$((counter + 3))
done

ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NAMESPACE}" \
    get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d)

echo ""
log_info "✅ ArgoCD installé et prêt."
echo ""
echo "  Mot de passe admin : ${ARGOCD_PASSWORD}"
echo ""
echo "  Sauvegardé dans ./argocd/.argocd-admin-password (gitignore, ne pas committer)"
echo "${ARGOCD_PASSWORD}" > ./argocd/.argocd-admin-password
chmod 600 ./argocd/.argocd-admin-password

# -----------------------------------------------------------------------------
# 4. Déploiement de l'ApplicationSet
# -----------------------------------------------------------------------------
log_step "=== DÉPLOIEMENT DE L'APPLICATIONSET ==="
kubectl apply -f ./argocd/applicationset.yaml

log_info "ApplicationSet déployé. ArgoCD va détecter les 4 charts depuis GitHub."
log_info "Les Applications sont en sync MANUEL — rien n'est appliqué automatiquement."
echo ""
log_info "Prochaine étape : make argocd-ui pour accéder à l'interface."
