#!/bin/bash
set -e

echo "=== Configuration de l'Agent K3s ==="

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

echo "Attente du token du master..."
timeout=300
counter=0
until [ -f /vagrant/node-token ] && [ -s /vagrant/node-token ]; do
    if [ $counter -gt $timeout ]; then
        echo "ERREUR: Token du master non trouvé après ${timeout}s"
        exit 1
    fi
    echo "Attente du token... ($counter/${timeout}s)"
    sleep 5
    counter=$((counter + 5))
done

echo "Attente de la disponibilité du master sur ${MASTER_IP}:6443..."
timeout=180
counter=0
until nc -z ${MASTER_IP} 6443 2>/dev/null; do
    if [ $counter -gt $timeout ]; then
        echo "ERREUR: Master inaccessible sur 6443 après ${timeout}s"
        exit 1
    fi
    echo "Attente master... ($counter/${timeout}s)"
    sleep 5
    counter=$((counter + 5))
done

K3S_TOKEN=$(cat /vagrant/node-token)
echo "Token récupéré avec succès."

echo "Installation de K3s Agent..."

if [ -f "${K3S_LOCAL_BIN}" ]; then
    echo "Binaire local détecté (${K3S_LOCAL_BIN}) -> installation sans téléchargement."
    curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
    chmod +x /tmp/k3s-install.sh
    install -o root -g root -m 0755 "${K3S_LOCAL_BIN}" /usr/local/bin/k3s

    INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_SKIP_START=true \
    K3S_URL="https://${MASTER_IP}:6443" \
    K3S_TOKEN="${K3S_TOKEN}" \
    INSTALL_K3S_EXEC="--node-ip ${AGENT_IP} --node-name agent" /tmp/k3s-install.sh

    echo "Démarrage du service k3s-agent..."
    systemctl start k3s-agent
else
    echo "Pas de binaire local -> téléchargement via get.k3s.io."
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="${K3S_VERSION}" \
        K3S_URL="https://${MASTER_IP}:6443" \
        K3S_TOKEN="${K3S_TOKEN}" \
        INSTALL_K3S_EXEC="--node-ip ${AGENT_IP} --node-name agent" sh -
fi

echo "Vérification que le process k3s-agent tourne..."
timeout=60
counter=0
until pgrep -f "k3s agent" &>/dev/null; do
    if [ $counter -gt $timeout ]; then
        echo "ERREUR: k3s-agent non démarré après ${timeout}s"
        journalctl -u k3s-agent -n 20 --no-pager || true
        exit 1
    fi
    echo "Attente du démarrage du process k3s agent... ($counter/${timeout}s)"
    sleep 5
    counter=$((counter + 5))
done
echo "Process k3s agent actif (PID $(pgrep -f 'k3s agent' | head -1))."

# -----------------------------------------------------------------------------
# Préchargement des images Cilium avec les bons tags (incluant les digests)
# -----------------------------------------------------------------------------
CILIUM_IMAGES_DIR="/vagrant/cilium-images"
if [ -d "${CILIUM_IMAGES_DIR}" ] && ls "${CILIUM_IMAGES_DIR}"/*.tar &>/dev/null; then
    echo "Images Cilium locales détectées -> import avec tags complets..."
    
    # Définir les mappings image -> fichier avec les tags exacts
    declare -A IMAGE_MAP=(
        ["quay.io/cilium/cilium:v1.20.1"]="cilium.tar"
        ["quay.io/cilium/cilium:v1.20.1@sha256:ae9ea21f7427fe24bc6ea7247eb552157a1b0a431744045d3f641545ca71d11b"]="cilium.tar"
        ["quay.io/cilium/operator-generic:v1.20.1"]="operator-generic.tar"
        ["quay.io/cilium/operator-generic:v1.20.1@sha256:6c3885fc7b629099fdbe2a5c87869c86feb825fa18fae299eac0f61918d16ecf"]="operator-generic.tar"
        ["quay.io/cilium/cilium-envoy:v1.37.5-1786810558-766ccfb37260a43e9d228837aa84ce3faf9f64e7"]="cilium-envoy.tar"
        ["quay.io/cilium/cilium-envoy:v1.37.5-1786810558-766ccfb37260a43e9d228837aa84ce3faf9f64e7@sha256:75b8094c7127736a2ffd2dce3945e0931cb6df21b0372ff661940eca26730b91"]="cilium-envoy.tar"
    )
    
    # Importer chaque image avec tous ses tags
    for image in "${!IMAGE_MAP[@]}"; do
        tarfile="${CILIUM_IMAGES_DIR}/${IMAGE_MAP[$image]}"
        if [ -f "$tarfile" ]; then
            echo "Import de $tarfile avec tag: $image"
            k3s ctr images import --digests "$tarfile" || true
        fi
    done
    
    # Vérification
    echo "Images importées dans containerd:"
    k3s ctr images list | grep cilium || echo "⚠️ Aucune image Cilium trouvée"
else
    echo "Pas d'images Cilium locales -> elles seront tirées depuis quay.io (peut être lent)."
fi

echo "=== Provisionnement Agent terminé ==="