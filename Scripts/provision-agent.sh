#!/bin/bash
# Script de provisionnement pour l'agent K3s
# provision-agent.sh

set -e

echo "=== Configuration de l'Agent K3s ==="

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

# Attendre que le token du master soit disponible
echo "Attente du token du master..."
timeout=300  # 5 minutes
counter=0
until [ -f /vagrant/node-token ]; do
    if [ $counter -gt $timeout ]; then
        echo "ERREUR: Timeout - Token du master non trouvé"
        exit 1
    fi
    echo "Attente du token... ($counter/$timeout)"
    sleep 5
    counter=$((counter + 5))
done

# Vérifier que le master est accessible
echo "Vérification de la connectivité avec le master..."
until nc -z ${MASTER_IP} 6443; do
    echo "Attente de la disponibilité du master sur ${MASTER_IP}:6443..."
    sleep 5
done

# Lire le token
K3S_TOKEN=$(cat /vagrant/node-token)
if [ -z "$K3S_TOKEN" ]; then
    echo "ERREUR: Token vue"
    exit 1
fi

echo "Token récupéré avec succès"

# === DÉTECTION AUTOMATIQUE DE L'INTERFACE ===
echo "Détection de l'interface host-only..."
HOST_ONLY_INTERFACE=$(ip -o addr show | grep "192.168.56." | awk '{print $2}')
if [ -z "$HOST_ONLY_INTERFACE" ]; then
    echo "ERREUR: Interface host-only non trouvée!"
    ip -o addr show
    exit 1
fi
echo "Interface host-only détectée: $HOST_ONLY_INTERFACE"
# =============================================

# Installation de K3s Agent
echo "Installation de K3s Agent..."
curl -sfL https://get.k3s.io | \
    K3S_URL=https://${MASTER_IP}:6443 \
    K3S_TOKEN=$K3S_TOKEN \
    INSTALL_K3S_EXEC="--node-ip ${AGENT_IP} --flannel-iface=$HOST_ONLY_INTERFACE" sh -


echo "=== Provisionnement Agent terminé ==="