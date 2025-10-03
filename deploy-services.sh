#!/bin/bash

# Configuration
KUBECONFIG_FILE="./kubeconfig"
K8S_MANIFESTS_DIR="./k8s-manifests"

# Couleurs
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

function print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

function print_error() {
    echo -e "${RED}❌ $1${NC}"
}

function print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

function print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

function print_header() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🚀 $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

function check_prerequisites() {
    print_info "Vérification des prérequis..."
    
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl n'est pas installé"
        exit 1
    fi
    
    if [ ! -f "$KUBECONFIG_FILE" ]; then
        print_error "Kubeconfig non trouvé: $KUBECONFIG_FILE"
        print_info "Exécutez d'abord: ./orchestrator.sh create"
        exit 1
    fi
    
    export KUBECONFIG=$KUBECONFIG_FILE
    
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Impossible de se connecter au cluster"
        print_info "Vérifiez que le cluster est démarré: ./orchestrator.sh status"
        exit 1
    fi
    
    print_success "Prérequis validés"
}

function deploy_namespaces() {
    print_header "Déploiement des Namespaces"
    
    kubectl apply -f $K8S_MANIFESTS_DIR/00-namespace.yaml
    
    if [ $? -eq 0 ]; then
        print_success "Namespaces créés"
        kubectl get namespaces | grep pwc
    else
        print_error "Échec de la création des namespaces"
        exit 1
    fi
}

function deploy_volumes() {
    print_header "Déploiement des Volumes Persistants"
    
    kubectl apply -f $K8S_MANIFESTS_DIR/volumes/
    
    if [ $? -eq 0 ]; then
        print_success "Volumes créés"
        sleep 5
        kubectl get pv
        kubectl get pvc -A
    else
        print_error "Échec de la création des volumes"
        exit 1
    fi
}

function deploy_databases() {
    print_header "Déploiement des Bases de Données"
    
    print_info "Déploiement des secrets..."
    kubectl apply -f $K8S_MANIFESTS_DIR/database/00-secrets.yaml
    
    print_info "Déploiement de Billing Database..."
    kubectl apply -f $K8S_MANIFESTS_DIR/database/01-billing-database.yaml
    
    print_info "Déploiement de Inventory Database..."
    kubectl apply -f $K8S_MANIFESTS_DIR/database/02-inventory-database.yaml
    
    if [ $? -eq 0 ]; then
        print_success "Bases de données déployées"
        print_info "Attente que les bases de données soient prêtes (30s)..."
        sleep 30
        kubectl get pods -n pwc-database
    else
        print_error "Échec du déploiement des bases de données"
        exit 1
    fi
}

function deploy_rabbitmq() {
    print_header "Déploiement de RabbitMQ"
    
    kubectl apply -f $K8S_MANIFESTS_DIR/rabbitmq/
    
    if [ $? -eq 0 ]; then
        print_success "RabbitMQ déployé"
        print_info "Attente que RabbitMQ soit prêt (30s)..."
        sleep 30
        kubectl get pods -n pwc-messaging
        kubectl get svc -n pwc-messaging
    else
        print_error "Échec du déploiement de RabbitMQ"
        exit 1
    fi
}

function deploy_applications() {
    print_header "Déploiement des Applications"
    
    # Créer le dossier apps s'il n'existe pas
    mkdir -p $K8S_MANIFESTS_DIR/apps
    
    print_info "Déploiement de Billing App..."
    kubectl apply -f $K8S_MANIFESTS_DIR/apps/billing-app.yaml
    
    print_info "Déploiement de Inventory App..."
    kubectl apply -f $K8S_MANIFESTS_DIR/apps/inventory-app.yaml
    
    print_info "Déploiement de API Gateway..."
    kubectl apply -f $K8S_MANIFESTS_DIR/apps/api-gateway.yaml
    
    if [ $? -eq 0 ]; then
        print_success "Applications déployées"
        print_info "Attente que les applications soient prêtes (30s)..."
        sleep 30
        kubectl get pods -n play-with-container
        kubectl get svc -n play-with-container
    else
        print_error "Échec du déploiement des applications"
        exit 1
    fi
}

function wait_for_pods() {
    print_header "Attente de tous les pods"
    
    print_info "Attente des pods dans pwc-database..."
    kubectl wait --for=condition=ready pod -l tier=database -n pwc-database --timeout=300s
    
    print_info "Attente des pods dans pwc-messaging..."
    kubectl wait --for=condition=ready pod -l app=rabbitmq -n pwc-messaging --timeout=300s
    
    print_info "Attente des pods dans play-with-container..."
    kubectl wait --for=condition=ready pod -l tier=backend -n play-with-container --timeout=300s
    kubectl wait --for=condition=ready pod -l tier=frontend -n play-with-container --timeout=300s
    
    print_success "Tous les pods sont prêts!"
}

function show_status() {
    print_header "État du Déploiement"
    
    echo -e "${CYAN}=== Namespaces ===${NC}"
    kubectl get namespaces | grep -E "NAME|pwc|play-with"
    
    echo -e "\n${CYAN}=== Volumes ===${NC}"
    kubectl get pv
    echo ""
    kubectl get pvc -A
    
    echo -e "\n${CYAN}=== Bases de Données ===${NC}"
    kubectl get all -n pwc-database
    
    echo -e "\n${CYAN}=== RabbitMQ ===${NC}"
    kubectl get all -n pwc-messaging
    
    echo -e "\n${CYAN}=== Applications ===${NC}"
    kubectl get all -n play-with-container
}

function show_access_info() {
    print_header "Informations d'Accès"
    
    # Récupérer l'IP du master
    MASTER_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    
    echo -e "${GREEN}🌐 API Gateway${NC}"
    echo -e "   URL: http://$MASTER_IP:30080"
    echo -e "   ou:  http://192.168.56.110:30080"
    echo ""
    
    echo -e "${GREEN}🐰 RabbitMQ Management${NC}"
    echo -e "   URL: http://$MASTER_IP:31672"
    echo -e "   ou:  http://192.168.56.110:31672"
    echo -e "   User: admin"
    echo -e "   Password: rabbitmq_password_123"
    echo ""
    
    echo -e "${GREEN}📊 Services disponibles${NC}"
    echo -e "   Billing Service:   http://$MASTER_IP:30080/billing"
    echo -e "   Inventory Service: http://$MASTER_IP:30080/inventory"
    echo ""
    
    echo -e "${CYAN}💡 Commandes utiles:${NC}"
    echo -e "   Voir les logs d'un pod:"
    echo -e "   kubectl logs -f <pod-name> -n <namespace>"
    echo ""
    echo -e "   Exec dans un pod:"
    echo -e "   kubectl exec -it <pod-name> -n <namespace> -- /bin/bash"
    echo ""
    echo -e "   Port-forward un service:"
    echo -e "   kubectl port-forward svc/<service-name> <local-port>:<service-port> -n <namespace>"
}

function deploy_all() {
    print_header "Déploiement Complet de Play with Container"
    
    check_prerequisites
    deploy_namespaces
    deploy_volumes
    deploy_databases
    deploy_rabbitmq
    deploy_applications
    wait_for_pods
    show_status
    show_access_info
    
    print_success "\n🎉 Déploiement complet réussi!"
}

function undeploy_all() {
    print_header "Suppression de tous les déploiements"
    
    read -p "Êtes-vous sûr de vouloir tout supprimer? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Annulé"
        exit 0
    fi
    
    print_info "Suppression des applications..."
    kubectl delete -f $K8S_MANIFESTS_DIR/apps/ --ignore-not-found=true
    
    print_info "Suppression de RabbitMQ..."
    kubectl delete -f $K8S_MANIFESTS_DIR/rabbitmq/ --ignore-not-found=true
    
    print_info "Suppression des bases de données..."
    kubectl delete -f $K8S_MANIFESTS_DIR/database/ --ignore-not-found=true
    
    print_info "Suppression des volumes..."
    kubectl delete -f $K8S_MANIFESTS_DIR/volumes/ --ignore-not-found=true
    
    print_info "Suppression des namespaces..."
    kubectl delete -f $K8S_MANIFESTS_DIR/00-namespace.yaml --ignore-not-found=true
    
    print_success "Tout a été supprimé"
}

function restart_service() {
    local service=$1
    local namespace=$2
    
    if [ -z "$service" ] || [ -z "$namespace" ]; then
        print_error "Usage: $0 restart <service-name> <namespace>"
        exit 1
    fi
    
    print_info "Redémarrage de $service dans $namespace..."
    kubectl rollout restart deployment/$service -n $namespace
    kubectl rollout status deployment/$service -n $namespace
    print_success "Service redémarré"
}

function scale_service() {
    local service=$1
    local replicas=$2
    local namespace=$3
    
    if [ -z "$service" ] || [ -z "$replicas" ] || [ -z "$namespace" ]; then
        print_error "Usage: $0 scale <service-name> <replicas> <namespace>"
        exit 1
    fi
    
    print_info "Scaling $service à $replicas réplicas..."
    kubectl scale deployment/$service --replicas=$replicas -n $namespace
    kubectl rollout status deployment/$service -n $namespace
    print_success "Service scalé"
}

function show_logs() {
    local service=$1
    local namespace=$2
    
    if [ -z "$service" ] || [ -z "$namespace" ]; then
        print_error "Usage: $0 logs <service-name> <namespace>"
        exit 1
    fi
    
    POD=$(kubectl get pods -n $namespace -l app=$service -o jsonpath='{.items[0].metadata.name}')
    
    if [ -z "$POD" ]; then
        print_error "Aucun pod trouvé pour $service dans $namespace"
        exit 1
    fi
    
    print_info "Logs de $POD..."
    kubectl logs -f $POD -n $namespace
}

function show_help() {
    cat << EOF
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${CYAN}  Play with Container - Déploiement K8s${NC}
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

${GREEN}Usage:${NC} $0 [COMMAND] [OPTIONS]

${GREEN}Commandes principales:${NC}
  ${YELLOW}deploy${NC}              Déployer toute l'infrastructure
  ${YELLOW}undeploy${NC}            Supprimer tous les déploiements
  ${YELLOW}status${NC}              Afficher l'état de tous les services
  ${YELLOW}info${NC}                Afficher les informations d'accès

${GREEN}Commandes de gestion:${NC}
  ${YELLOW}restart${NC} <svc> <ns>  Redémarrer un service
  ${YELLOW}scale${NC} <svc> <n> <ns> Scaler un service à N réplicas
  ${YELLOW}logs${NC} <svc> <ns>     Afficher les logs d'un service

${GREEN}Déploiements partiels:${NC}
  ${YELLOW}deploy-ns${NC}           Déployer uniquement les namespaces
  ${YELLOW}deploy-volumes${NC}      Déployer uniquement les volumes
  ${YELLOW}deploy-db${NC}           Déployer uniquement les bases de données
  ${YELLOW}deploy-rabbitmq${NC}     Déployer uniquement RabbitMQ
  ${YELLOW}deploy-apps${NC}         Déployer uniquement les applications

${GREEN}Exemples:${NC}
  # Déploiement complet
  $0 deploy

  # Voir l'état
  $0 status

  # Redémarrer une app
  $0 restart billing-app play-with-container

  # Scaler une app
  $0 scale inventory-app 3 play-with-container

  # Voir les logs
  $0 logs api-gateway play-with-container

  # Tout supprimer
  $0 undeploy

${GREEN}Namespaces utilisés:${NC}
  - play-with-container  (Applications)
  - pwc-database         (Bases de données)
  - pwc-messaging        (RabbitMQ)
  - pwc-monitoring       (Monitoring - futur)

EOF
}

# Main
export KUBECONFIG=$KUBECONFIG_FILE

case "$1" in
    deploy)
        deploy_all
        ;;
    undeploy)
        undeploy_all
        ;;
    status)
        check_prerequisites
        show_status
        ;;
    info)
        check_prerequisites
        show_access_info
        ;;
    restart)
        check_prerequisites
        restart_service "$2" "$3"
        ;;
    scale)
        check_prerequisites
        scale_service "$2" "$3" "$4"
        ;;
    logs)
        check_prerequisites
        show_logs "$2" "$3"
        ;;
    deploy-ns)
        check_prerequisites
        deploy_namespaces
        ;;
    deploy-volumes)
        check_prerequisites
        deploy_volumes
        ;;
    deploy-db)
        check_prerequisites
        deploy_databases
        ;;
    deploy-rabbitmq)
        check_prerequisites
        deploy_rabbitmq
        ;;
    deploy-apps)
        check_prerequisites
        deploy_applications
        ;;
    *)
        show_help
        exit 1
        ;;
esac