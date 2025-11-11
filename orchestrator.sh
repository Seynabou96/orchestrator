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
    fi
    
    # Destruction des VMs
    log_info "Destruction des VMs Vagrant..."
    vagrant destroy -f
    
    # Nettoyage des fichiers locaux
    log_info "Nettoyage des fichiers de configuration..."
    rm -f kubeconfig node-token
    
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
        log_info "Pods:"
        kubectl get pods -o wide
        
        echo ""
        log_info "Services:"
        kubectl get services
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
  create    Crée le cluster K3s avec Vagrant
  start     Démarre le cluster et déploie toutes les ressources
  stop      Arrête le cluster proprement
  delete    Supprime complètement le cluster et ses données
  status    Affiche l'état du cluster
  help      Affiche cette aide

Exemples:
  ./orchestrator.sh create   # Créer le cluster
  ./orchestrator.sh start    # Démarrer et déployer
  ./orchestrator.sh stop     # Arrêter
  ./orchestrator.sh delete   # Supprimer tout

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