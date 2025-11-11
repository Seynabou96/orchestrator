#!/bin/bash

# Script de configuration kubectl pour l'hôte
# setup-kubectl.sh

set -e

echo "=== Configuration de kubectl sur l'hôte ==="

# Vérifier que le cluster est déployé
if [ ! -f "./kubeconfig" ]; then
    echo "ERREUR: Fichier kubeconfig non trouvé"
    echo "Assurez-vous que le cluster K3s est déployé avec 'vagrant up'"
    exit 1
fi

# Installer kubectl si nécessaire
if ! command -v kubectl &> /dev/null; then
    echo "Installation de kubectl..."
    
    # Détecter l'OS
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            echo "Architecture non supportée: $ARCH"
            exit 1
            ;;
    esac
    
    # Télécharger kubectl
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
    
    # Installer kubectl
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    
    echo "kubectl ${KUBECTL_VERSION} installé avec succès"
else
    echo "kubectl est déjà installé: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

# Créer le répertoire .kube s'il n'existe pas
mkdir -p ~/.kube

# Sauvegarder la config existante si elle existe
if [ -f ~/.kube/config ]; then
    echo "Sauvegarde de la configuration kubectl existante..."
    cp ~/.kube/config ~/.kube/config.backup.$(date +%Y%m%d-%H%M%S)
fi

# Copier la nouvelle configuration
echo "Configuration de kubectl avec le cluster K3s..."
cp ./kubeconfig ~/.kube/config

# Vérifier les permissions
chmod 600 ~/.kube/config

# Tester la connexion
echo "Test de la connexion au cluster..."
if kubectl cluster-info &>/dev/null; then
    echo "✅ Connexion au cluster réussie !"
    echo ""
    echo "=== Informations du cluster ==="
    kubectl cluster-info
    echo ""
    echo "=== Nœuds du cluster ==="
    kubectl get nodes -o wide
    echo ""
    echo "=== Pods système ==="
    kubectl get pods -n kube-system
    echo ""
else
    echo "❌ Échec de la connexion au cluster"
    echo "Vérifiez que les VMs sont bien démarrées avec 'vagrant status'"
    exit 1
fi

# Installer kubectl completion si bash est utilisé
if [[ $SHELL == *"bash"* ]]; then
    echo "Configuration de l'auto-complétion bash pour kubectl..."
    
    # Vérifier si bash-completion est installé
    if command -v kubectl &> /dev/null && [ -d /usr/share/bash-completion/completions/ ]; then
        kubectl completion bash | sudo tee /usr/share/bash-completion/completions/kubectl > /dev/null
        
        # Ajouter l'alias et l'auto-complétion au .bashrc si pas déjà présent
        if ! grep -q "alias k=kubectl" ~/.bashrc; then
            echo "" >> ~/.bashrc
            echo "# Kubectl aliases and completion" >> ~/.bashrc
            echo "alias k=kubectl" >> ~/.bashrc
            echo "complete -F __start_kubectl k" >> ~/.bashrc
        fi
        
        echo "Auto-complétion configurée. Redémarrez votre terminal ou exécutez 'source ~/.bashrc'"
    fi
fi

echo ""
echo "=== Configuration kubectl terminée avec succès ==="
echo ""
echo "Commandes utiles :"
echo "  kubectl get nodes              # Voir les nœuds"
echo "  kubectl get pods -A            # Voir tous les pods"
echo "  kubectl create deployment test-nginx --image=nginx"
echo "  kubectl get deployments        # Voir les déploiements"
echo "  kubectl delete deployment test-nginx"
echo ""
echo "Pour plus d'informations :"
echo "  kubectl --help"
echo "  kubectl get --help"
echo ""

echo "=========================================="
echo "Configuration de kubectl terminée !"
echo "=========================================="