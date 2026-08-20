#!/bin/bash
# =============================================================================
# setup-dashboard-admin.sh — Crée le ServiceAccount admin, génère le
# token, lance le proxy kubectl et ouvre le navigateur.
#
# Logique reprise telle quelle de l'ancienne fonction deploy_dashboard()
# d'orchestrator.sh, extraite ici en script indépendant pour que
# Makefile (cible `make dashboard`) reste lisible.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

open_browser() {
    local url=$1
    if command -v xdg-open &> /dev/null; then
        xdg-open "$url" &>/dev/null &
    elif command -v open &> /dev/null; then
        open "$url" &>/dev/null &
    elif command -v start &> /dev/null; then
        start "$url" &>/dev/null &
    else
        log_warn "Impossible d'ouvrir automatiquement le navigateur"
        log_info "Ouvrez manuellement: $url"
    fi
}

log_info "Création du ServiceAccount admin..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

sleep 5

log_info "Génération du token d'accès..."
TOKEN=$(kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null || true)

if [ -z "$TOKEN" ]; then
    log_warn "create token a échoué, tentative avec la méthode alternative (anciennes versions K8s)..."
    SECRET_NAME=$(kubectl -n kubernetes-dashboard get serviceaccount admin-user -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)
    if [ -n "$SECRET_NAME" ]; then
        TOKEN=$(kubectl -n kubernetes-dashboard get secret "$SECRET_NAME" -o jsonpath='{.data.token}' | base64 -d)
    fi
fi

echo "$TOKEN" > dashboard-token.txt

echo ""
log_info "✅ Dashboard déployé."
echo ""
log_info "Token d'accès (sauvegardé dans dashboard-token.txt):"
echo "$TOKEN"
echo ""

if command -v xclip &> /dev/null; then
    echo -n "$TOKEN" | xclip -selection clipboard 2>/dev/null && log_info "Token copié (xclip)"
elif command -v pbcopy &> /dev/null; then
    echo -n "$TOKEN" | pbcopy 2>/dev/null && log_info "Token copié (pbcopy)"
elif command -v clip.exe &> /dev/null; then
    echo -n "$TOKEN" | clip.exe 2>/dev/null && log_info "Token copié (clip.exe, WSL)"
fi

echo ""
read -p "Voulez-vous lancer le dashboard maintenant ? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    log_info "Démarrage du proxy kubectl en arrière-plan..."
    pkill -f "kubectl proxy" 2>/dev/null || true
    sleep 2
    kubectl proxy &>/dev/null &
    PROXY_PID=$!
    echo $PROXY_PID > .dashboard-proxy.pid
    log_info "Proxy démarré (PID: $PROXY_PID)"
    sleep 3

    DASHBOARD_URL="http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
    log_info "Ouverture du dashboard dans le navigateur..."
    open_browser "$DASHBOARD_URL"

    echo ""
    log_info "✅ Dashboard ouvert ! Collez le token pour vous connecter."
    log_warn "Pour arrêter le proxy : make stop-dashboard (ou kill $PROXY_PID)"
else
    echo ""
    log_info "Pour lancer le dashboard manuellement :"
    echo "  1. kubectl proxy"
    echo "  2. Ouvrez : http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
    echo "  3. Collez le token depuis dashboard-token.txt"
fi
