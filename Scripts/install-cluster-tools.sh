#!/bin/bash
set -euo pipefail

MASTER_IP="192.168.56.10"
CLUSTER_CIDR="10.42.0.0/16"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

# -----------------------------------------------------------------------------
# 0. API server accessible ?
# -----------------------------------------------------------------------------
log_step "=== VÉRIFICATION DE L'ACCÈS À L'API KUBERNETES ==="
timeout=60
counter=0
until kubectl get --raw='/readyz' &>/dev/null; do
    if [ $counter -gt $timeout ]; then
        log_error "API inaccessible après ${timeout}s. Lancez Scripts/setup-kubectl.sh d'abord."
        exit 1
    fi
    log_info "Attente de l'API server... ($counter/${timeout}s)"
    sleep 5
    counter=$((counter + 5))
done
log_info "API accessible."

# -----------------------------------------------------------------------------
# 1. Attendre que le nœud master s'enregistre avant d'installer Cilium.
#    Sans ça, Cilium est schedulé sur 0 nœuds → ses pods ne démarrent jamais.
# -----------------------------------------------------------------------------
log_step "=== ATTENTE DE L'ENREGISTREMENT DES NŒUDS ==="
timeout=180
counter=0
until [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge 1 ]; do
    if [ $counter -ge $timeout ]; then
        log_error "Aucun nœud enregistré après ${timeout}s."
        log_error "Vérifiez: vagrant ssh master -- journalctl -u k3s -n 50"
        exit 1
    fi
    log_info "Attente de l'enregistrement du nœud master... ($counter/${timeout}s)"
    sleep 10
    counter=$((counter + 10))
done
log_info "$(kubectl get nodes --no-headers 2>/dev/null | wc -l) nœud(s) enregistré(s)."

# -----------------------------------------------------------------------------
# 2. Helm
# -----------------------------------------------------------------------------
log_step "=== INSTALLATION DE HELM ==="
if command -v helm &>/dev/null; then
    log_info "Helm déjà installé ($(helm version --short))"
else
    log_info "Installation de Helm..."
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod +x /tmp/get_helm.sh
    /tmp/get_helm.sh
    rm -f /tmp/get_helm.sh
fi

# -----------------------------------------------------------------------------
# 3. Cilium CNI
#    kubeProxyReplacement=true : requis car K3s a été lancé avec
#    --disable-kube-proxy. Cilium gère le trafic Service via eBPF.
#    NetworkPolicy standard (networking.k8s.io/v1) est enforced
#    nativement par Cilium sans option supplémentaire.
#    ingressController : remplace Traefik (désactivé dans K3s).
# -----------------------------------------------------------------------------
log_step "=== INSTALLATION DE CILIUM (CNI + NetworkPolicy) ==="
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update

if helm status cilium -n kube-system &>/dev/null; then
    log_warn "Cilium déjà installé, skip."
else
    log_info "Installation de Cilium (avec retry si l'apiserver n'est pas encore stable)..."
    timeout=180
    counter=0
    until helm install cilium cilium/cilium \
        --namespace kube-system \
        --set operator.replicas=1 \
        --set ipam.operator.clusterPoolIPv4PodCIDRList="{${CLUSTER_CIDR}}" \
        --set k8sServiceHost="${MASTER_IP}" \
        --set k8sServicePort=6443 \
        --set kubeProxyReplacement=true \
        --set ingressController.enabled=true \
        --set ingressController.loadbalancerMode=shared 2>&1; do
        if [ $counter -ge $timeout ]; then
            log_error "helm install cilium a échoué après ${timeout}s."
            exit 1
        fi
        log_warn "helm install cilium a échoué, nouvel essai dans 10s... ($counter/${timeout}s)"
        sleep 10
        counter=$((counter + 10))
    done

    log_info "Attente que Cilium soit prêt..."
    # 1200s (20 min) : sans préchargement des images (voir POSTMORTEM #13/#14),
    # le pull de l'image cilium principale (~300-400 Mo) peut prendre 15-25 min
    # sur un réseau à débit limité. Avec préchargement, ça passe en <1 min.
    timeout=1200
    counter=0
    until [ "$(kubectl -n kube-system get daemonset cilium \
               -o jsonpath='{.status.numberReady}' 2>/dev/null)" -ge 1 ] 2>/dev/null; do
        if [ $counter -ge $timeout ]; then
            log_warn "Cilium daemonset pas Ready après ${timeout}s — on continue."
            kubectl get pods -n kube-system -l k8s-app=cilium || true
            break
        fi
        log_info "Cilium daemonset pas encore Ready... ($counter/${timeout}s)"
        sleep 15
        counter=$((counter + 15))
    done

    counter=0
    until [ "$(kubectl -n kube-system get deployment cilium-operator \
               -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" -ge 1 ] 2>/dev/null; do
        if [ $counter -ge $timeout ]; then
            log_warn "Cilium operator pas Ready après ${timeout}s — on continue."
            break
        fi
        sleep 10
        counter=$((counter + 10))
    done
fi

# Après l'installation de Cilium, ajoute :
log_step "=== VÉRIFICATION ET CORRECTION DES PODS CILIUM BLOQUÉS ==="

# Attendre que les pods démarrent
sleep 30

# Vérifier les pods bloqués
BLOCKED_PODS=$(kubectl get pods -n kube-system -l k8s-app=cilium -o json | jq -r '.items[] | select(.status.phase != "Running") | .metadata.name')

if [ -n "$BLOCKED_PODS" ]; then
    log_warn "Pods Cilium bloqués détectés: $BLOCKED_PODS"
    
    # Vérifier si c'est un problème d'image
    for pod in $BLOCKED_PODS; do
        NODE=$(kubectl get pod -n kube-system $pod -o jsonpath='{.spec.nodeName}')
        log_info "Vérification du pod $pod sur le nœud $NODE..."
        
        # Vérifier les événements
        kubectl describe pod -n kube-system $pod | grep -A 5 "Events:"
        
        # Si c'est un problème de pull, redémarrer le pod
        kubectl delete pod -n kube-system $pod
        log_info "Pod $pod redémarré"
    done
    
    # Attendre que les pods redémarrent
    sleep 30
fi

# Vérification finale
log_info "État des pods Cilium:"
kubectl get pods -n kube-system -l k8s-app=cilium -o wide

# -----------------------------------------------------------------------------
# 4. Vérification nœuds Ready
# -----------------------------------------------------------------------------
log_step "=== VÉRIFICATION : LES NŒUDS DOIVENT MAINTENANT ÊTRE READY ==="
timeout=300
counter=0
until kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready "; do
    if [ $counter -ge $timeout ]; then
        log_warn "Nœuds pas encore Ready après ${timeout}s."
        kubectl get pods -n kube-system -l k8s-app=cilium || true
        break
    fi
    log_info "Attente des nœuds Ready... ($counter/${timeout}s)"
    sleep 10
    counter=$((counter + 10))
done
kubectl get nodes -o wide || true

# -----------------------------------------------------------------------------
# 5. Sealed Secrets
# -----------------------------------------------------------------------------
log_step "=== INSTALLATION DU CONTRÔLEUR SEALED SECRETS ==="
# IMPORTANT (corrigé) : le repo a migré de bitnami-labs vers bitnami le
# 15 juin 2026. L'ancienne URL GitHub Pages (bitnami-labs.github.io)
# retourne 404 depuis cette date — confirmé (bitnami/sealed-secrets#1982).
# Pas de "|| true" ici : si l'URL change encore, on veut voir l'erreur
# tout de suite plutôt que de la masquer (c'est ce "|| true" qui a fait
# échouer silencieusement le repo add précédemment).
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo update

if helm status sealed-secrets -n kube-system &>/dev/null; then
    log_warn "Sealed Secrets déjà installé, skip."
else
    helm install sealed-secrets sealed-secrets/sealed-secrets \
        --namespace kube-system \
        --set fullnameOverride=sealed-secrets-controller

    log_info "Attente que le contrôleur Sealed Secrets soit prêt..."
    # 300s : dépend des nœuds Ready (donc de Cilium) — voir POSTMORTEM #13/#14.
    kubectl -n kube-system rollout status deployment/sealed-secrets-controller --timeout=300s
fi

# -----------------------------------------------------------------------------
# 6. kubeseal CLI
# -----------------------------------------------------------------------------
log_step "=== INSTALLATION DE KUBESEAL (CLI) ==="
if command -v kubeseal &>/dev/null; then
    log_info "kubeseal déjà installé ($(kubeseal --version 2>&1))"
else
    KUBESEAL_VERSION="0.27.0"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) log_error "Architecture non gérée: $ARCH"; exit 1 ;;
    esac
    log_info "Téléchargement de kubeseal v${KUBESEAL_VERSION} (${ARCH})..."
    curl -sSL -o /tmp/kubeseal.tar.gz \
        "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-${ARCH}.tar.gz"
    tar -xzf /tmp/kubeseal.tar.gz -C /tmp kubeseal
    sudo install -m 755 /tmp/kubeseal /usr/local/bin/kubeseal
    rm -f /tmp/kubeseal.tar.gz /tmp/kubeseal
    log_info "kubeseal installé: $(kubeseal --version 2>&1)"
fi

# -----------------------------------------------------------------------------
# 7. Certificat public Sealed Secrets
# -----------------------------------------------------------------------------
log_step "=== RÉCUPÉRATION DU CERTIFICAT PUBLIC SEALED SECRETS ==="
mkdir -p ./.secrets-cert
kubeseal --fetch-cert \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    > ./.secrets-cert/pub-sealed-secrets.pem
log_info "Certificat sauvegardé dans ./.secrets-cert/pub-sealed-secrets.pem"
log_warn "Ce fichier est PUBLIC — il peut être commité. .secrets-cert/ est dans .gitignore par précaution."

echo ""
log_info "✅ Cluster opérationnel : Cilium (CNI + NetworkPolicy enforced) + Sealed Secrets."
log_info "   Prochaine étape : Scripts/seal-secrets.sh"