#!/bin/bash
set -e

# À lancer sur l'HÔTE, à la racine du projet (à côté du Vagrantfile).
# Nécessite Docker installé sur l'hôte.
# Pré-télécharge les images Cilium (CNI) une seule fois, pour éviter de les
# re-pull depuis quay.io à chaque "vagrant destroy && vagrant up".
# Voir docs/troubleshooting/POSTMORTEM.md #13/#14.

OUT_DIR="cilium-images"
mkdir -p "${OUT_DIR}"

# Tags + digests exacts utilisés par le chart Helm cilium/cilium v1.20.1
# (confirmés via kubectl describe pod / events sur un déploiement réel)
IMAGES=(
  "quay.io/cilium/cilium:v1.20.1@sha256:ae9ea21f7427fe24bc6ea7247eb552157a1b0a431744045d3f641545ca71d11b|cilium.tar"
  "quay.io/cilium/operator-generic:v1.20.1@sha256:6c3885fc7b629099fdbe2a5c87869c86feb825fa18fae299eac0f61918d16ecf|operator-generic.tar"
  "quay.io/cilium/cilium-envoy:v1.37.5-1786810558-766ccfb37260a43e9d228837aa84ce3faf9f64e7@sha256:75b8094c7127736a2ffd2dce3945e0931cb6df21b0372ff661940eca26730b91|cilium-envoy.tar"
)

for entry in "${IMAGES[@]}"; do
    IMAGE="${entry%%|*}"
    FILE="${entry##*|}"
    if [ -f "${OUT_DIR}/${FILE}" ]; then
        echo "Déjà présent: ${OUT_DIR}/${FILE} (skip)"
        continue
    fi
    echo "=== Pull: ${IMAGE} ==="
    docker pull "${IMAGE}"
    echo "=== Save: ${OUT_DIR}/${FILE} ==="
    docker save -o "${OUT_DIR}/${FILE}" "${IMAGE}"
done

echo ""
echo "Images prêtes dans ${OUT_DIR}/ :"
ls -lh "${OUT_DIR}"
echo ""
echo "Prochaine étape: vagrant destroy -f && vagrant up"
echo "(les scripts provision-master.sh / provision-agent.sh les importeront automatiquement)"