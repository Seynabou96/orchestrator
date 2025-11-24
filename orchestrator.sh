#!/bin/bash
set -e

# Couleurs pour les logs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Fonctions de logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Fonction pour attendre que les pods soient prêts
wait_for_pods() {
    local label=$1
    local timeout=${2:-300}
    
    log_info "Attente des pods avec label $label (timeout: ${timeout}s)..."
    kubectl wait --for=condition=ready pod -l "$label" --timeout="${timeout}s" 2>/dev/null || {
        log_warning "Timeout atteint pour $label, continuons..."
        return 0
    }
}

# Fonction pour ouvrir une URL dans le navigateur par défaut
open_browser() {
    local url=$1
    if command -v xdg-open &> /dev/null; then
        xdg-open "$url" &>/dev/null &
    elif command -v open &> /dev/null; then
        open "$url" &>/dev/null &
    elif command -v start &> /dev/null; then
        start "$url" &>/dev/null &
    else
        log_warning "Impossible d'ouvrir automatiquement le navigateur"
        log_info "Ouvrez manuellement: $url"
    fi
}

# Fonction pour déployer le dashboard Kubernetes
deploy_dashboard() {
    log_step "=== DÉPLOIEMENT DU KUBERNETES DASHBOARD ==="
    
    # Vérifier que kubectl fonctionne
    if ! kubectl get nodes &>/dev/null; then
        log_error "kubectl ne peut pas se connecter au cluster"
        exit 1
    fi
    
    # 1. Déployer le dashboard
    log_info "📊 Déploiement du Kubernetes Dashboard..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
    
    # Attendre que le dashboard soit déployé
    log_info "Attente du déploiement du dashboard..."
    sleep 10
    wait_for_pods "k8s-app=kubernetes-dashboard" 180 -n kubernetes-dashboard
    
    # 2. Créer le compte service admin
    log_info "👤 Création du compte service admin..."
    
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
    
    # 3. Obtenir le token d'accès
    log_info "🔑 Génération du token d'accès..."
    
    # Créer un token pour le service account
    TOKEN=$(kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null)
    
    if [ -z "$TOKEN" ]; then
        log_warning "Impossible de créer un token avec 'create token', utilisation de la méthode alternative..."
        # Méthode alternative pour les anciennes versions
        SECRET_NAME=$(kubectl -n kubernetes-dashboard get serviceaccount admin-user -o jsonpath='{.secrets[0].name}' 2>/dev/null)
        if [ -n "$SECRET_NAME" ]; then
            TOKEN=$(kubectl -n kubernetes-dashboard get secret $SECRET_NAME -o jsonpath='{.data.token}' | base64 -d)
        fi
    fi
    
    # Sauvegarder le token dans un fichier
    echo "$TOKEN" > dashboard-token.txt
    
    echo ""
    log_info "✅ Dashboard déployé avec succès!"
    echo ""
    log_step "=== INFORMATIONS D'ACCÈS AU DASHBOARD ==="
    echo ""
    log_info "📝 Token d'accès (sauvegardé dans dashboard-token.txt):"
    echo ""
    echo "$TOKEN"
    echo ""
    log_info "🌐 Le token a été copié dans votre presse-papiers (si xclip/pbcopy disponible)"
    
    # Copier le token dans le presse-papiers
    if command -v xclip &> /dev/null; then
        echo -n "$TOKEN" | xclip -selection clipboard 2>/dev/null && log_info "✓ Token copié (Linux - xclip)"
    elif command -v pbcopy &> /dev/null; then
        echo -n "$TOKEN" | pbcopy 2>/dev/null && log_info "✓ Token copié (macOS - pbcopy)"
    elif command -v clip.exe &> /dev/null; then
        echo -n "$TOKEN" | clip.exe 2>/dev/null && log_info "✓ Token copié (Windows WSL - clip.exe)"
    fi
    
    echo ""
    
    # Demander si on lance automatiquement
    read -p "Voulez-vous lancer le dashboard maintenant ? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        log_info "🚀 Démarrage du proxy kubectl en arrière-plan..."
        
        # Tuer les anciens processus kubectl proxy
        pkill -f "kubectl proxy" 2>/dev/null || true
        sleep 2
        
        # Démarrer le proxy en arrière-plan
        kubectl proxy &>/dev/null &
        PROXY_PID=$!
        echo $PROXY_PID > .dashboard-proxy.pid
        
        log_info "Proxy démarré (PID: $PROXY_PID)"
        sleep 3
        
        # URL du dashboard
        DASHBOARD_URL="http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
        
        log_info "🌐 Ouverture du dashboard dans le navigateur..."
        open_browser "$DASHBOARD_URL"
        
        echo ""
        log_info "✅ Dashboard ouvert! Collez le token pour vous connecter."
        echo ""
        log_warning "💡 Pour arrêter le proxy plus tard, utilisez:"
        echo -e "   ${YELLOW}kill $PROXY_PID${NC}   ou   ${YELLOW}./orchestrator.sh stop-dashboard${NC}"
        echo ""
    else
        echo ""
        log_info "Pour lancer le dashboard manuellement:"
        echo ""
        echo "  1. Démarrez le proxy kubectl:"
        echo -e "     ${YELLOW}kubectl proxy${NC}"
        echo ""
        echo "  2. Ouvrez votre navigateur à l'adresse:"
        echo -e "     ${YELLOW}http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/${NC}"
        echo ""
        echo "  3. Utilisez le token sauvegardé dans dashboard-token.txt"
        echo ""
    fi
}

# Fonction pour arrêter le proxy du dashboard
stop_dashboard_proxy() {
    log_step "=== ARRÊT DU PROXY DASHBOARD ==="
    
    if [ -f ".dashboard-proxy.pid" ]; then
        PID=$(cat .dashboard-proxy.pid)
        if ps -p $PID > /dev/null 2>&1; then
            log_info "Arrêt du proxy (PID: $PID)..."
            kill $PID 2>/dev/null || true
            rm -f .dashboard-proxy.pid
            log_info "✅ Proxy arrêté"
        else
            log_warning "Le processus n'est plus actif"
            rm -f .dashboard-proxy.pid
        fi
    else
        log_warning "Aucun fichier PID trouvé, tentative d'arrêt de tous les kubectl proxy..."
        pkill -f "kubectl proxy" 2>/dev/null && log_info "✅ Proxy(s) arrêté(s)" || log_warning "Aucun proxy actif trouvé"
    fi
}

# Fonction create - Création du cluster
create_cluster() {
    log_step "=== CRÉATION DU CLUSTER K3S ==="
    
    # Vérifier si Vagrant est installé
    if ! command -v vagrant &> /dev/null; then
        log_error "Vagrant n'est pas installé"
        exit 1
    fi
    
    # Vérifier si le cluster existe déjà
    if vagrant status | grep -q "running"; then
        log_warning "Le cluster semble déjà exister"
        read -p "Voulez-vous le recréer ? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Destruction du cluster existant..."
            vagrant destroy -f
        else
            log_info "Utilisation du cluster existant"
            return 0
        fi
    fi
    
    # Démarrer les VMs
    log_info "Démarrage des VMs Vagrant..."
    vagrant up
    
    # Configuration de kubectl sur l'hôte
    log_info "Configuration de kubectl sur l'hôte..."
    if [ -f "./Scripts/setup-kubectl.sh" ]; then
        bash ./Scripts/setup-kubectl.sh
    else
        log_warning "setup-kubectl.sh non trouvé, configuration manuelle nécessaire"
    fi
    
    # Vérifier que kubectl fonctionne
    log_info "Vérification de la connexion kubectl..."
    if ! kubectl get nodes &>/dev/null; then
        log_error "kubectl ne peut pas se connecter au cluster"
        exit 1
    fi
    
    # Attendre que les nœuds soient Ready
    log_info "Attente que les nœuds soient prêts..."
    for i in {1..60}; do
        if kubectl get nodes | grep -q "Ready"; then
            READY_NODES=$(kubectl get nodes --no-headers | grep -c "Ready" || echo 0)
            if [ "$READY_NODES" -ge 2 ]; then
                log_info "Tous les nœuds sont prêts"
                break
            fi
        fi
        [ $i -eq 60 ] && {
            log_error "Timeout: les nœuds ne sont pas prêts"
            exit 1
        }
        sleep 5
    done
    
    echo ""
    log_info "✅ Cluster créé avec succès"
    kubectl get nodes -o wide
}

# Fonction start - Démarrage du cluster et déploiement
start_cluster() {
    log_step "=== DÉMARRAGE DU CLUSTER ==="
    
    # Vérifier si les VMs existent
    if ! vagrant status | grep -q "master"; then
        log_error "Le cluster n'existe pas. Utilisez './orchestrator.sh create' d'abord"
        exit 1
    fi
    
    # Démarrer les VMs si elles sont arrêtées
    if ! vagrant status | grep -q "running"; then
        log_info "Démarrage des VMs..."
        vagrant up
        sleep 30  # Attendre que K3s démarre
    else
        log_info "Les VMs sont déjà démarrées"
    fi
    
    # Vérifier kubectl
    if ! kubectl get nodes &>/dev/null; then
        log_warning "kubectl non configuré, reconfiguration..."
        if [ -f "./Scripts/setup-kubectl.sh" ]; then
            bash ./Scripts/setup-kubectl.sh
        fi
    fi
    
    # Déploiement des ressources Kubernetes
    log_step "=== DÉPLOIEMENT DES RESSOURCES KUBERNETES ==="
    
    # 1. Secrets
    log_info "📝 Déploiement des secrets..."
    kubectl apply -f ./Manifests/Secrets/billing-db-secret.yaml
    kubectl apply -f ./Manifests/Secrets/inventory-db-secret.yaml
    kubectl apply -f ./Manifests/Secrets/rabbitmq-secret.yaml
    sleep 2
    
    # 2. Bases de données
    log_info "💾 Déploiement des bases de données..."
    kubectl apply -f ./Manifests/billing-database.yaml
    kubectl apply -f ./Manifests/inventory-database.yaml

    log_info "Attente que les bases de données soient prêtes (3-5 min)..."
    wait_for_pods "app=billing-database" 300
    wait_for_pods "app=inventory-database" 300
    
    # 3. RabbitMQ
    log_info "🐰 Déploiement de RabbitMQ..."
    kubectl apply -f ./Manifests/rabbitmq.yaml

    log_info "Attente que RabbitMQ soit prêt (2-3 min)..."
    wait_for_pods "app=rabbitmq" 300
    
    # 4. Applications backend
    log_info "📱 Déploiement des applications backend..."
    kubectl apply -f ./Manifests/billing-app.yaml
    kubectl apply -f ./Manifests/inventory-app.yaml

    log_info "Attente que les applications soient prêtes (2-3 min)..."
    wait_for_pods "app=billing-app" 300
    wait_for_pods "app=inventory-app" 300
    
    # 5. API Gateway
    log_info "🌐 Déploiement de l'API Gateway..."
    kubectl apply -f ./Manifests/api-gateway.yaml

    log_info "Attente que l'API Gateway soit prêt..."
    wait_for_pods "app=api-gateway" 300
    
    # 6. Dashboard Kubernetes
    read -p "Voulez-vous déployer le Kubernetes Dashboard ? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        deploy_dashboard
    fi
    
    echo ""
    log_info "✅ Cluster démarré et toutes les ressources déployées"
    echo ""
    log_step "=== STATUS FINAL ==="
    kubectl get pods -o wide
    echo ""
    kubectl get services
    echo ""
    
    # Afficher l'URL d'accès
    EXTERNAL_IP=$(kubectl get service api-gateway-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    if [ "$EXTERNAL_IP" != "pending" ] && [ -n "$EXTERNAL_IP" ]; then
        log_info "🌍 API Gateway accessible sur: http://$EXTERNAL_IP:3000"
    else
        NODEPORT=$(kubectl get service api-gateway-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
        if [ -n "$NODEPORT" ]; then
            log_info "🌍 API Gateway accessible via NodePort: http://192.168.56.10:$NODEPORT"
        else
            log_info "🌍 API Gateway accessible via port-forward: kubectl port-forward service/api-gateway-service 3000:3000"
        fi
    fi
}

# Fonction stop - Arrêt du cluster
stop_cluster() {
    log_step "=== ARRÊT DU CLUSTER ==="
    
    # Vérifier si le cluster existe
    if ! vagrant status | grep -q "master"; then
        log_error "Le cluster n'existe pas"
        exit 1
    fi
    
    # Arrêt gracieux optionnel des applications
    read -p "Voulez-vous faire un arrêt gracieux des applications ? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Arrêt gracieux des applications..."
        kubectl scale deployment api-gateway-deployment --replicas=0 2>/dev/null || true
        kubectl scale statefulset billing-app --replicas=0 2>/dev/null || true
        kubectl scale deployment inventory-app-deployment --replicas=0 2>/dev/null || true
        sleep 10
        kubectl scale statefulset rabbitmq --replicas=0 2>/dev/null || true
        kubectl scale statefulset billing-database --replicas=0 2>/dev/null || true
        kubectl scale statefulset inventory-database --replicas=0 2>/dev/null || true
        sleep 10
    fi
    
    # Arrêt des VMs
    log_info "Arrêt des VMs Vagrant..."
    vagrant halt
    
    # Arrêter le proxy du dashboard s'il est actif
    if [ -f ".dashboard-proxy.pid" ]; then
        PID=$(cat .dashboard-proxy.pid)
        if ps -p $PID > /dev/null 2>&1; then
            log_info "Arrêt du proxy dashboard..."
            kill $PID 2>/dev/null || true
            rm -f .dashboard-proxy.pid
        fi
    fi
    
    log_info "✅ Cluster arrêté"
}

# Fonction delete - Suppression complète
delete_cluster() {
    log_step "=== SUPPRESSION DU CLUSTER ==="
    
    log_warning "⚠️  Cette action va supprimer définitivement le cluster et toutes ses données"
    read -p "Êtes-vous sûr ? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Annulation"
        exit 0
    fi
    
    # Suppression des ressources Kubernetes (optionnel)
    if kubectl get nodes &>/dev/null 2>&1; then
        log_info "Suppression des ressources Kubernetes..."
        kubectl delete all,pvc,secrets,configmaps --all --ignore-not-found=true 2>/dev/null || true
        kubectl delete namespace kubernetes-dashboard --ignore-not-found=true 2>/dev/null || true
    fi
    
    # Destruction des VMs
    log_info "Destruction des VMs Vagrant..."
    vagrant destroy -f
    
    # Arrêter le proxy du dashboard s'il est actif
    if [ -f ".dashboard-proxy.pid" ]; then
        PID=$(cat .dashboard-proxy.pid)
        kill $PID 2>/dev/null || true
    fi
    pkill -f "kubectl proxy" 2>/dev/null || true
    
    # Nettoyage des fichiers locaux
    log_info "Nettoyage des fichiers de configuration..."
    rm -f kubeconfig node-token dashboard-token.txt .dashboard-proxy.pid
    
    log_info "✅ Cluster supprimé"
}

# Fonction status - Affichage du statut
status_cluster() {
    log_step "=== STATUS DU CLUSTER ==="
    
    # Status Vagrant
    echo ""
    log_info "Status des VMs:"
    vagrant status
    
    # Status Kubernetes
    if kubectl get nodes &>/dev/null 2>&1; then
        echo ""
        log_info "Nœuds Kubernetes:"
        kubectl get nodes -o wide
        
        echo ""
        log_info "Pods (namespace default):"
        kubectl get pods -o wide
        
        echo ""
        log_info "Services (namespace default):"
        kubectl get services
        
        # Vérifier si le dashboard est déployé
        if kubectl get namespace kubernetes-dashboard &>/dev/null 2>&1; then
            echo ""
            log_info "Dashboard Kubernetes:"
            kubectl get pods -n kubernetes-dashboard
            echo ""
            if [ -f "dashboard-token.txt" ]; then
                log_info "Token du dashboard disponible dans: dashboard-token.txt"
            fi
        fi
    else
        log_warning "kubectl non configuré ou cluster non accessible"
    fi
}

# Fonction d'aide
show_help() {
    cat << EOF
Usage: ./orchestrator.sh [COMMAND]

Gestion du cluster K3s pour le projet orchestrator

Commandes:
  create          Crée le cluster K3s avec Vagrant
  start           Démarre le cluster et déploie toutes les ressources
  stop            Arrête le cluster proprement
  delete          Supprime complètement le cluster et ses données
  status          Affiche l'état du cluster
  dashboard       Déploie le Kubernetes Dashboard et l'ouvre dans le navigateur
  stop-dashboard  Arrête le proxy du dashboard
  help            Affiche cette aide

Exemples:
  ./orchestrator.sh create          # Créer le cluster
  ./orchestrator.sh start           # Démarrer et déployer (inclut option dashboard)
  ./orchestrator.sh dashboard       # Déployer et ouvrir le dashboard
  ./orchestrator.sh stop-dashboard  # Arrêter le proxy du dashboard
  ./orchestrator.sh stop            # Arrêter
  ./orchestrator.sh delete          # Supprimer tout

Note: Le dashboard s'ouvre automatiquement dans votre navigateur avec le token
      copié dans le presse-papiers (si disponible)

EOF
}

# Main - Traitement des arguments
case "${1:-}" in
    create)
        create_cluster
        ;;
    start)
        start_cluster
        ;;
    stop)
        stop_cluster
        ;;
    delete)
        delete_cluster
        ;;
    status)
        status_cluster
        ;;
    dashboard)
        deploy_dashboard
        ;;
    stop-dashboard)
        stop_dashboard_proxy
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Commande invalide: ${1:-}"
        echo ""
        show_help
        exit 1
        ;;
esac