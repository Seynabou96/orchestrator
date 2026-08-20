#!/bin/bash
set -e

echo "=== Configuration du Master K3s ==="

MASTER_IP="192.168.56.10"
AGENT_IP="192.168.56.11"
K3S_VERSION="v1.36.2+k3s1"
K3S_LOCAL_BIN="/vagrant/k3s-bin/k3s"

echo "Mise à jour du système..."
apt-get update -y

echo "Configuration des hosts..."
cat >> /etc/hosts <<HOSTS
${MASTER_IP} master
${AGENT_IP} agent
HOSTS

echo "Configuration DNS..."
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
unlink /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf <<RESOLV
nameserver 8.8.8.8
nameserver 1.1.1.1
search cluster.local
RESOLV
chattr +i /etc/resolv.conf

echo "Installation de K3s Master..."

INSTALL_K3S_EXEC_FLAGS="\
  --write-kubeconfig-mode 644 \
  --node-ip ${MASTER_IP} \
  --advertise-address ${MASTER_IP} \
  --bind-address ${MASTER_IP} \
  --node-name master \
  --disable traefik \
  --disable-kube-proxy \
  --flannel-backend=none \
  --disable-network-policy"

if [ -f "${K3S_LOCAL_BIN}" ]; then
    # Binaire pré-téléchargé présent (ex: réseau avec débit CDN GitHub insuffisant)
    # -> on saute le téléchargement, méthode air-gap officielle k3s.
    echo "Binaire local détecté (${K3S_LOCAL_BIN}) -> installation sans téléchargement."
    curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
    chmod +x /tmp/k3s-install.sh
    install -o root -g root -m 0755 "${K3S_LOCAL_BIN}" /usr/local/bin/k3s

    INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_SKIP_START=true \
    INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC_FLAGS}" /tmp/k3s-install.sh
else
    # Chemin par défaut : téléchargement direct (fonctionne pour la plupart des réseaux).
    # Voir docs/troubleshooting/POSTMORTEM.md #13 si ça bloque/traîne sur ce téléchargement :
    # placer un binaire dans ./k3s-bin/k3s (voir README) pour passer en mode local.
    echo "Pas de binaire local -> téléchargement via get.k3s.io."
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="${K3S_VERSION}" \
      INSTALL_K3S_SKIP_START=true \
      INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC_FLAGS}" sh -
fi

echo "Démarrage du service k3s..."
systemctl start k3s

echo "Attente de l'écriture du token et du kubeconfig par k3s..."
timeout=120
counter=0
until [ -s /var/lib/rancher/k3s/server/node-token ] && [ -s /etc/rancher/k3s/k3s.yaml ]; do
    if [ $counter -gt $timeout ]; then
        echo "ERREUR: token/kubeconfig non écrits après ${timeout}s"
        journalctl -u k3s -n 30 --no-pager || true
        exit 1
    fi
    echo "Attente token/kubeconfig... ($counter/${timeout}s)"
    sleep 5
    counter=$((counter + 5))
done
echo "Token et kubeconfig présents."

echo "Sauvegarde du token..."
cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token

echo "Préparation de la config kubectl..."
cp /etc/rancher/k3s/k3s.yaml /vagrant/kubeconfig
sed -i "s/127.0.0.1/${MASTER_IP}/g" /vagrant/kubeconfig

echo "État du cluster (NotReady normal — Cilium pas encore installé) :"
kubectl get nodes -o wide || true

# -----------------------------------------------------------------------------
# Préchargement des images Cilium (si présentes) — évite de re-pull depuis
# quay.io à chaque destroy/up sur un réseau à débit limité.
# Voir docs/troubleshooting/POSTMORTEM.md #13/#14.
# -----------------------------------------------------------------------------
CILIUM_IMAGES_DIR="/vagrant/cilium-images"
if [ -d "${CILIUM_IMAGES_DIR}" ] && ls "${CILIUM_IMAGES_DIR}"/*.tar &>/dev/null; then
    echo "Images Cilium locales détectées -> import direct dans containerd."
    for tarfile in "${CILIUM_IMAGES_DIR}"/*.tar; do
        echo "  Import: ${tarfile}"
        k3s ctr images import "${tarfile}"
    done
else
    echo "Pas d'images Cilium locales -> elles seront tirées depuis quay.io par Helm (peut être lent, voir POSTMORTEM #13/#14)."
fi

apt-get install -y curl wget git nano htop

echo ""
echo "=== Master K3s configuré avec succès ==="
echo "IP Master: ${MASTER_IP}"
echo "Token sauvé dans: /vagrant/node-token"
echo "Config kubectl sauvée dans: /vagrant/kubeconfig"
echo ""
echo "=== Provisionnement Master terminé ==="