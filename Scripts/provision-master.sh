#!/bin/bash

# Script de provisionnement pour le master K3s
# provision-master.sh

set -e

echo "=== Configuration du Master K3s ==="

# Configuration des variables
MASTER_IP="192.168.56.10"
AGENT_IP="192.168.56.11"

# Mise à jour du système
echo "Mise à jour du système..."
apt-get update -y

# Configuration des hosts
echo "Configuration des hosts..."
cat >> /etc/hosts <<EOF
${MASTER_IP} master
${AGENT_IP} agent
EOF

# Configuration DNS pour éviter les problèmes systemd-resolved
echo "Configuration DNS..."
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
unlink /etc/resolv.conf 2>/dev/null || true

cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
search cluster.local
EOF

# Protection du fichier resolv.conf
chattr +i /etc/resolv.conf

# Installation de K3s Master avec configuration réseau explicite
echo "Installation de K3s Master..."
# Ajoutez cette ligne AVANT l'installation de K3s
echo "Détection de l'interface réseau..."
HOST_ONLY_INTERFACE=$(ip addr show | grep "192.168.56." | awk '{print $NF}' | head -1)
echo "Interface host-only détectée: $HOST_ONLY_INTERFACE"

# Puis utilisez-la dans la commande K3s
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="\
  --write-kubeconfig-mode 644 \
  --node-ip ${MASTER_IP} \
  --advertise-address ${MASTER_IP} \
  --bind-address ${MASTER_IP} \
  --cluster-init \
  --disable traefik \
  --flannel-iface=$HOST_ONLY_INTERFACE" sh -    # ← Utilise l'interface détectée

# Attendre que K3s soit prêt
echo "Attente du démarrage de K3s..."
sleep 10

# Vérifier que K3s fonctionne
until kubectl get nodes &>/dev/null; do
    echo "Attente de la disponibilité de K3s..."
    sleep 5
done

echo "K3s Master démarré avec succès"

# Sauvegarder le token pour l'agent
echo "Sauvegarde du token..."
cat /var/lib/rancher/k3s/server/node-token > /vagrant/node-token

# Copier la config kubectl pour l'hôte
echo "Préparation de la config kubectl..."
# Copier le kubeconfig pour kubectl
cp /etc/rancher/k3s/k3s.yaml /vagrant/kubeconfig
# Mettre à jour l'IP dans le kubeconfig
sed -i "s/127.0.0.1/${MASTER_IP}/g" /vagrant/kubeconfig

# Vérifier l'état du cluster
echo "État du cluster:"
kubectl get nodes -o wide

# Installer quelques outils utiles
echo "Installation d'outils complémentaires..."
apt-get install -y curl wget git nano htop

# Afficher des informations utiles
echo ""
echo "=== Master K3s configuré avec succès ==="
echo "IP Master: ${MASTER_IP}"
echo "Token sauvé dans: /vagrant/node-token"
echo "Config kubectl sauvée dans: /vagrant/kubeconfig"
echo ""
echo "Commandes utiles sur le master:"
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo "  kubectl cluster-info"
echo ""

echo "=== Provisionnement Master terminé ==="