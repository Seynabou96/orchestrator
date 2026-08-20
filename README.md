# 🚀 Orchestrator — Microservices sur K3s (Helm + Cilium + Sealed Secrets)

Déploiement d'une architecture microservices sur K3s, packagé en charts Helm, avec CNI Cilium et secrets chiffrés (Sealed Secrets). Base réutilisée pour le projet Cloud Design (EKS).

## ⚠️ Important

`charts/` est la **seule source de vérité**. Le dossier `Manifests/` est **périmé** (archive de l'avant-Helm), ne pas l'utiliser.

## 📦 Structure

```
Dockerfiles/        # code source + Dockerfiles (copie à jour de play-with-containers)
charts/
├── inventory/      # inventory-app + inventory-database
├── billing/        # billing-app + billing-database + rabbitmq
├── api-gateway/    # api-gateway (seul point d'entrée externe)
└── monitoring/      # Prometheus + Grafana + Loki/Alloy
Scripts/
├── build-and-push-images.sh   # build + push des 6 images sur Docker Hub
├── install-cluster-tools.sh   # Helm, Cilium, Sealed Secrets controller
├── seal-secrets.sh            # génère les SealedSecret (interactif)
└── setup-dashboard-admin.sh   # Kubernetes Dashboard
Makefile            # point d'entrée : make create / seal / start / status / ...
```

3 namespaces : `inventory`, `billing` (avec rabbitmq), `api-gateway`.

`Dockerfiles/` est une copie à jour du code source de [play-with-containers](https://github.com/Seynabou96/play-with-containers) (projet séparé sur GitHub, où ce code a été développé et testé en premier). Elle est dupliquée ici pour que ce repo soit autonome — quelqu'un qui clone seulement `orchestrator` doit pouvoir comprendre et rebuilder sans dépendre d'un autre repo.

## ⚙️ Prérequis réseau (binaire k3s)

`make create` télécharge le binaire k3s (~78 Mo) depuis le CDN de releases GitHub. Sur certains réseaux, ce téléchargement peut être très lent (débit soutenu insuffisant vers ce CDN précis, indépendant de `curl`/VirtualBox — voir `docs/troubleshooting/POSTMORTEM.md` #13).

**Si `vagrant up` semble bloqué à `[INFO] Downloading binary` pendant plusieurs minutes sans progression visible :** pas la peine d'attendre des heures, télécharge le binaire une fois en amont sur l'hôte, à la racine du projet (à côté du `Vagrantfile`) :

```bash
mkdir -p k3s-bin
curl -Lo k3s-bin/k3s https://github.com/k3s-io/k3s/releases/download/v1.36.2+k3s1/k3s
chmod +x k3s-bin/k3s
# vérifier l'intégrité :
sha256sum k3s-bin/k3s
# doit correspondre à : 65a55ec56c24eab44383086166ec620a491952b7e23941a49ddca6e8a4c4b4de
```

`provision-master.sh` et `provision-agent.sh` détectent automatiquement ce fichier et sautent le téléchargement. Sans ce fichier, le comportement par défaut (téléchargement normal) reste inchangé — cette étape n'est nécessaire que si le téléchargement direct traîne.

**Même logique pour les images Cilium (CNI)**, tirées depuis `quay.io` lors de `make create` — sur un réseau à débit limité, l'image principale (~300-400 Mo) peut prendre 15-25 min, et ce à **chaque** `vagrant destroy && vagrant up` (contrairement au binaire k3s, téléchargé une seule fois par VM). Si `make create` échoue sur Sealed Secrets avec des pods Cilium bloqués en `Init:0/6` (voir `docs/troubleshooting/POSTMORTEM.md` #14) :

```bash
# Sur l'hôte, une fois (nécessite Docker) :
bash Scripts/download-cilium-images.sh
# télécharge et sauvegarde les 3 images Cilium dans ./cilium-images/

vagrant destroy -f && vagrant up
# les scripts importent automatiquement les images dans containerd sur chaque VM
```

## 🚀 Démarrage

```bash
# 1. Build + push les images (une fois, ou après modif du code)
bash Scripts/build-and-push-images.sh ./Dockerfiles

# 2. Crée les VMs, installe Cilium (CNI) + Sealed Secrets controller
make create

# 3. Génère les secrets chiffrés (demande les mots de passe, ou Entrée = aléatoire)
make seal

# 4. Télécharge la dépendance Helm de monitoring (1ère fois)
make helm-deps

# 5. Déploie les 4 charts (inventory, billing, api-gateway, monitoring)
make start

# 6. Vérifie que tout tourne
make status
```

## 🔧 Commandes utiles

| Commande | Effet |
|---|---|
| `make status` | Nœuds, pods, releases Helm, HPA, Ingress |
| `make test-smoke` | Health check + flux inventory/billing via api-gateway |
| `make lint` / `make template` | Valider les charts avant de les appliquer |
| `make debug` | Historique Helm, valeurs effectives, manifests appliqués |
| `make stop` | Désinstalle les apps (garde les VMs) |
| `make delete` | Détruit les VMs (`vagrant destroy`) |
| `make dashboard` | Déploie/ouvre le Kubernetes Dashboard |

## 📊 Grafana

Pas d'Ingress pour Grafana (volontaire, pour rester simple). Accès :

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3001:80
```
Puis ouvrir `http://localhost:3001` (user `admin`, mot de passe dans `charts/monitoring/values.yaml`, à changer avant tout usage réel). La datasource Loki (logs) est déjà connectée automatiquement.

⚠️ **Ne pas utiliser le port local 3000** : c'est celui d'`api-gateway` (voir `make test-smoke`). Un port-forward Grafana resté actif sur 3000 fait échouer silencieusement le test smoke avec des `401 Unauthorized` (c'est Grafana qui répond à la place de l'API) — déjà rencontré, voir `docs/troubleshooting/POSTMORTEM.md`.

## 📜 Logs

Loki (mode Monolithic, stockage filesystem) + Grafana Alloy (DaemonSet, collecte les logs de tous les pods). Alloy remplace Promtail, EOL depuis le 2 mars 2026.

## 🔐 Secrets

Les credentials (DB, RabbitMQ) sont des **SealedSecret** (Bitnami), committables sur GitHub sans risque — ils ne sont déchiffrables que par le contrôleur du cluster où ils ont été scellés (`make seal`). RabbitMQ a un secret scellé **deux fois** (`billing` + `api-gateway`), car Sealed Secrets chiffre par couple namespace+nom exact.

## 🕸️ Réseau

- **CNI** : Cilium (remplace Flannel) → NetworkPolicy natif, kube-proxy conservé.
- **Ingress** : Cilium natif (pas Traefik) pour `api-gateway`, seul service exposé.
- **NetworkPolicy** : `inventory` et `billing` ont un default-deny + règles explicites. `api-gateway` n'en a pas (trafic Ingress = identité `reserved:ingress`, voir commentaire dans `values.yaml`).

## ☁️ Vers EKS (Cloud Design)

Chaque chart a un `values-eks.yaml` (override de `storageClassName`, etc.). Points à traiter côté Cloud Design, pas ici : EBS CSI driver (StorageClass), AWS Load Balancer Controller (ALB vs Ingress Cilium), activation NetworkPolicy sur le VPC CNI.

## ❌ Non traité dans cette session

ArgoCD — gardé volontairement pour Code Keeper (comprendre Helm manuellement avant d'automatiser son déploiement).

## 🔄 ArgoCD (optionnel — complément à `make start`)

ArgoCD ajoute la synchronisation GitOps par-dessus le déploiement Helm existant. Il surveille le repo GitHub et détecte les diffs entre ce qui est dans `charts/` et ce qui tourne dans le cluster — sans jamais appliquer quoi que ce soit sans ta validation (sync manuel).

```bash
# Installer ArgoCD + déployer l'ApplicationSet
make argocd

# Ouvrir l'UI (http://localhost:8080, login admin)
make argocd-ui

# Voir l'état des 4 Applications détectées
make argocd-status

# Déclencher un sync manuel (applique les charts depuis GitHub)
make argocd-sync

# Supprimer ArgoCD (les charts Helm restent déployés)
make argocd-delete
```

**Structure** : une seule ressource `ApplicationSet` (`argocd/applicationset.yaml`) utilisant le **Git Directory generator** — elle détecte automatiquement chaque sous-dossier de `charts/` et crée une Application ArgoCD pour chacun (inventory, billing, api-gateway, monitoring).

**Sync manuel** : ArgoCD détecte les diffs mais n'applique rien sans ta validation — soit via `make argocd-sync`, soit via le bouton **Sync** dans l'UI.

## 🩹 Troubleshooting

En cas de comportement bizarre au provisioning (boucles infinies, redémarrages en boucle, pods en `CrashLoopBackOff`, téléchargement k3s/images Cilium qui traîne...), voir `docs/troubleshooting/POSTMORTEM.md` — 14 problèmes réels déjà rencontrés et résolus, avec la cause exacte de chacun.