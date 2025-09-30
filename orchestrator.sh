#!/bin/bash

# Script d'orchestration pour le cluster K3s
# Auteur: DevOps Project
# Description: Script pour créer, démarrer et arrêter le cluster K3s

set -e

# Couleurs pour les messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Fonction pour afficher les messages colorés
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Fonction pour vérifier si Vagrant est installé
check_vagrant() {
    if ! command -v vagrant &> /dev/null; then
        log_error "Vagrant n'est pas installé. Veuillez l'installer avant de continuer."
        exit 1
    fi
}

# Fonction pour vérifier si kubectl est installé
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl n'est pas installé."
        read -p "Voulez-vous l'installer automatiquement? (y/n): " install_kubectl
        if [[ $install_kubectl == "y" || $install_kubectl == "Y" ]]; then
            install_kubectl_binary
        else
            log_error "kubectl est requis pour gérer le cluster. Installation annulée."
            exit 1
        fi
    fi
}

# Fonction pour installer kubectl
install_kubectl_binary() {
    log_info "Installation de kubectl..."
    
    # Détection de l'OS
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
    esac
    
    # Téléchargement et installation
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/$OS/$ARCH/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    
    log_success "kubectl installé avec succès!"
}

# Fonction pour créer le cluster
create_cluster() {
    log_info "Création du cluster K3s..."
    
    check_vagrant
    
    # Vérification si le Vagrantfile existe
    if [[ ! -f "Vagrantfile" ]]; then
        log_error "Vagrantfile introuvable dans le répertoire courant."
        exit 1
    fi
    
    # Nettoyage des anciens fichiers
    rm -f node-token kubeconfig
    
    # Création des VMs
    log_info "Démarrage des machines virtuelles..."
    vagrant up
    
    # Attendre que le cluster soit prêt
    log_info "Attente de la disponibilité du cluster..."
    sleep 30
    
    # Configuration de kubectl
    if [[ -f "kubeconfig" ]]; then
        export KUBECONFIG=$(pwd)/kubeconfig
        log_success "Kubeconfig configuré: $(pwd)/kubeconfig"
        
        # Test de connectivité
        log_info "Test de connectivité au cluster..."
        if kubectl get nodes &> /dev/null; then
            log_success "cluster created"
            echo ""
            log_info "État des nœuds:"
            kubectl get nodes -o wide
            echo ""
            log_info "Pour utiliser kubectl, exécutez:"
            echo "export KUBECONFIG=$(pwd)/kubeconfig"
        else
            log_error "Impossible de se connecter au cluster"
            exit 1
        fi
    else
        log_error "Fichier kubeconfig introuvable"
        exit 1
    fi
}

# Fonction pour démarrer le cluster
start_cluster() {
    log_info "Démarrage du cluster K3s..."
    
    check_vagrant
    
    # Démarrage des VMs si elles sont arrêtées
    vagrant up
    
    # Attendre que les services soient prêts
    sleep 20
    
    if [[ -f "kubeconfig" ]]; then
        export KUBECONFIG=$(pwd)/kubeconfig
        
        # Vérification de l'état du cluster
        if kubectl get nodes &> /dev/null; then
            log_success "cluster started"
            echo ""
            kubectl get nodes -o wide
        else
            log_warning "Le cluster démarre encore, veuillez patienter..."
            sleep 30
            if kubectl get nodes &> /dev/null; then
                log_success "cluster started"
                kubectl get nodes -o wide
            else
                log_error "Échec du démarrage du cluster"
                exit 1
            fi
        fi
    else
        log_error "Fichier kubeconfig introuvable. Créez d'abord le cluster."
        exit 1
    fi
}

# Fonction pour arrêter le cluster
stop_cluster() {
    log_info "Arrêt du cluster K3s..."
    
    check_vagrant
    
    # Arrêt des VMs
    vagrant halt
    
    log_success "cluster stopped"
}

# Fonction pour détruire le cluster
destroy_cluster() {
    log_warning "Destruction complète du cluster K3s..."
    read -p "Êtes-vous sûr de vouloir détruire le cluster? (y/n): " confirm
    
    if [[ $confirm == "y" || $confirm == "Y" ]]; then
        check_vagrant
        
        # Destruction des VMs
        vagrant destroy -f
        
        # Nettoyage des fichiers
        rm -f node-token kubeconfig
        
        log_success "Cluster détruit avec succès"
    else
        log_info "Destruction annulée"
    fi
}

# Fonction pour afficher l'état du cluster
status_cluster() {
    log_info "État du cluster K3s..."
    
    if [[ -f "kubeconfig" ]]; then
        export KUBECONFIG=$(pwd)/kubeconfig
        
        echo ""
        log_info "État des VMs Vagrant:"
        vagrant status
        
        echo ""
        log_info "État des nœuds Kubernetes:"
        if kubectl get nodes &> /dev/null; then
            kubectl get nodes -o wide
            
            echo ""
            log_info "Pods système:"
            kubectl get pods -A
        else
            log_warning "Impossible de se connecter au cluster"
        fi
    else
        log_warning "Cluster non initialisé. Utilisez './orchestrator.sh create' d'abord."
    fi
}

# Fonction d'aide
show_help() {
    echo "Usage: $0 {create|start|stop|destroy|status|help}"
    echo ""
    echo "Commandes disponibles:"
    echo "  create   - Créer et démarrer le cluster K3s"
    echo "  start    - Démarrer le cluster existant"
    echo "  stop     - Arrêter le cluster"
    echo "  destroy  - Détruire complètement le cluster"
    echo "  status   - Afficher l'état du cluster"
    echo "  help     - Afficher cette aide"
    echo ""
    echo "Exemples:"
    echo "  $0 create    # Créer le cluster"
    echo "  $0 start     # Démarrer le cluster"
    echo "  $0 stop      # Arrêter le cluster"
    echo ""
}

# Script principal
case "$1" in
    "create")
        create_cluster
        ;;
    "start")
        start_cluster
        ;;
    "stop")
        stop_cluster
        ;;
    "destroy")
        destroy_cluster
        ;;
    "status")
        status_cluster
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    *)
        log_error "Commande invalide: $1"
        echo ""
        show_help
        exit 1
        ;;
esac