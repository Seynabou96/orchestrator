# 🚀 Orchestrator - Microservices sur K3s

Déploiement d'une architecture microservices complète sur un cluster K3s avec Vagrant et Kubernetes.

## 📋 Table des matières

- [Vue d'ensemble](#vue-densemble)
- [Architecture](#architecture)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Utilisation](#utilisation)
- [Configuration](#configuration)
- [Vérification](#vérification)
- [Troubleshooting](#troubleshooting)
- [Technologies utilisées](#technologies-utilisées)

---

## 🎯 Vue d'ensemble

Ce projet déploie une architecture microservices complète comprenant :

- **2 bases de données PostgreSQL** (Inventory & Billing) avec persistance
- **RabbitMQ** pour la messagerie asynchrone
- **3 applications** (Inventory-app, Billing-app, API Gateway)
- **Autoscaling horizontal** basé sur la consommation CPU
- **Gestion des secrets** Kubernetes
- **Cluster K3s** hautement disponible (1 master + 1 agent)

### Composants

| Composant | Type | Port | Réplicas | Scaling |
|-----------|------|------|----------|---------|
| inventory-database | StatefulSet | 5432 | 1 | Manuel |
| billing-database | StatefulSet | 5432 | 1 | Manuel |
| RabbitMQ | StatefulSet | 5672, 15672 | 1 | Manuel |
| inventory-app | Deployment | 8080 | 1-3 | Auto (60% CPU) |
| billing-app | StatefulSet | 8080 | 1 | Manuel |
| api-gateway | Deployment | 3000 | 1-3 | Auto (60% CPU) |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     API Gateway                         │
│                    (Port 3000)                          │
│              LoadBalancer / NodePort                    │
└────────────┬──────────────────────────┬─────────────────┘
             │                          │
     ┌───────▼──────────┐      ┌────────▼─────────┐
     │  Inventory-App   │      │   Billing-App    │
     │   (Port 8080)    │      │   (Port 8080)    │
     │   Deployment     │      │   StatefulSet    │
     └────────┬─────────┘      └────────┬─────────┘
              │                         │
     ┌────────▼─────────┐      ┌────────▼──────────┐
     │  Inventory-DB    │      │   Billing-DB      │
     │   PostgreSQL     │      │   PostgreSQL      │
     │   StatefulSet    │      │   StatefulSet     │
     └──────────────────┘      └────────┬──────────┘
                                        │
                               ┌────────▼──────────┐
                               │     RabbitMQ      │
                               │   StatefulSet     │
                               │  (Queue: billing) │
                               └───────────────────┘
```

### Flux de données

1. **Requêtes externes** → API Gateway (port 3000)
2. **API Gateway** → Inventory-App / Billing-App (port 8080)
3. **Inventory-App** → Inventory-Database (port 5432)
4. **Billing-App** ↔ Billing-Database (port 5432)
5. **Billing-App** ↔ RabbitMQ (port 5672) pour traitement asynchrone

---

## 📦 Prérequis

### Logiciels requis

- **Vagrant** ≥ 2.2.19
- **VirtualBox** ≥ 6.1
- **kubectl** (installé automatiquement par le script)
- **Minimum 6 GB RAM** disponible
- **20 GB d'espace disque**

### Système d'exploitation hôte

- Linux (Ubuntu 20.04+ recommandé)
- macOS 11+
- Windows 10/11 avec WSL2

### Vérification des prérequis

```bash
# Vérifier Vagrant
vagrant --version

# Vérifier VirtualBox
vboxmanage --version

# Vérifier la mémoire disponible
free -h  # Linux
vm_stat  # macOS
```

---

## ⚙️ Installation

### 1. Cloner le projet

```bash
git clone <https://learn.zone01dakar.sn/git/sniang/orchestrator.git>
cd orchestrator
```

### 2. Structure des fichiers

Assurez-vous d'avoir cette structure :

```
.
├── Manifests
│   └── [...]
├── Scripts
│   └── [...]
├── Dockerfiles
│   └── [...]
└── Vagrantfile
```

### 3. Rendre les scripts exécutables

```bash
cd Scripts/
chmod +x orchestrator.sh setup-kubectl.sh provision-master.sh provision-agent.sh
cd ..
```

---

## 🚀 Utilisation

### Commandes principales

Le script `orchestrator.sh` gère tout le cycle de vie du cluster :

```bash
# Créer le cluster K3s (master + agent)
./orchestrator.sh create

# Démarrer le cluster et déployer toutes les applications
./orchestrator.sh start

# Vérifier l'état du cluster
./orchestrator.sh status

# Arrêter le cluster proprement
./orchestrator.sh stop

# Supprimer complètement le cluster
./orchestrator.sh delete
```

### Workflow typique

```bash
# 1. Création initiale du cluster (première fois)
./orchestrator.sh create

# 2. Déploiement des applications
./orchestrator.sh start

# 3. Vérification du statut
./orchestrator.sh status

# Attendez 3-5 minutes que tous les pods soient Ready
kubectl get pods -w

# 4. Tester l'API Gateway
curl http://192.168.56.10:<NODEPORT>

# 5. Arrêt propre (optionnel)
./orchestrator.sh stop

# 6. Redémarrage
./orchestrator.sh start
```

---

## 🔧 Configuration

### Configuration réseau

Les VMs utilisent un réseau privé :

- **Master** : 192.168.56.10
- **Agent** : 192.168.56.11

### Ressources des pods

```yaml
# Exemple pour inventory-app
resources:
  requests:
    cpu: 150m
    memory: 200Mi
  limits:
    cpu: 300m
    memory: 400Mi
```

---

## ✅ Vérification

### Vérifier le cluster

```bash
# Statut des nœuds
kubectl get nodes -o wide

# Statut des pods
kubectl get pods -o wide

# Statut des services
kubectl get services

# Statut des volumes persistants
kubectl get pvc

# Logs d'un pod
kubectl logs <pod-name>

# Description détaillée
kubectl describe pod <pod-name>
```

### Vérifier l'autoscaling

```bash
# Vérifier les HPAs
kubectl get hpa

# Détails d'un HPA
kubectl describe hpa inventory-app-hpa

# Forcer un scale-up (stress test)
kubectl run -it --rm load-generator --image=busybox /bin/sh
# Dans le pod :
while true; do wget -q -O- http://inventory-app-service:8080; done
```

### Vérifier les bases de données

```bash
# Se connecter au pod PostgreSQL
kubectl exec -it inventory-database-0 -- psql -U inv_user -d movies_db 
#or
kubectl exec -it billing-database-0 -- psql -U billing_user -d billing_db
# liste des bases de données
billing_db=> \l
# liste des relations
billing_db=> \dt
# Liste les éléments de la table
billing_db=> TABLE orders;
# Vérifier RabbitMQ
kubectl exec -it rabbitmq-0 -- rabbitmqctl list_queues
```

### Accéder à l'API Gateway

```bash
# Obtenir le NodePort
kubectl get service api-gateway-service

# Tester l'API
curl http://192.168.56.10:<NODEPORT>/health
```

---

## 🛠️ Troubleshooting

### Les pods ne démarrent pas

```bash
# Vérifier les événements
kubectl get events --sort-by='.lastTimestamp'

# Vérifier les logs
kubectl logs <pod-name>

# Vérifier la description
kubectl describe pod <pod-name>
```

### Problèmes de réseau entre pods

```bash
# Tester la connectivité depuis un pod
kubectl run test-pod --rm -it --image=busybox -- /bin/sh
# Dans le pod :
wget -O- http://inventory-app-service:8080
nc -zv billing-database-service 5432
```

### RabbitMQ ne démarre pas

```bash
# Vérifier les permissions
kubectl logs rabbitmq-0

# Supprimer et recréer le PVC
kubectl delete pvc rabbitmq-data-rabbitmq-0
kubectl delete pod rabbitmq-0
```

### Kubectl ne se connecte pas

```bash
# Reconfigurer kubectl
bash setup-kubectl.sh

# Vérifier la config
kubectl config view

# Tester la connexion
kubectl cluster-info
```

### Les VMs ne démarrent pas

```bash
# Vérifier le statut Vagrant
vagrant status

# Voir les logs VirtualBox
vagrant up --debug

# Détruire et recréer
vagrant destroy -f
vagrant up
```

### Problèmes de mémoire

```bash
# Vérifier l'utilisation mémoire
kubectl top nodes
kubectl top pods

# Réduire les réplicas
kubectl scale deployment inventory-app-deployment --replicas=1
```

---

## 🛡️ Sécurité

### Bonnes pratiques implémentées

✅ **Secrets Kubernetes** : Credentials chiffrés  
✅ **Resource Limits** : Protection contre OOM  
✅ **Liveness/Readiness Probes** : Auto-récupération  


---

## 📊 Monitoring (Bonus)

### Métriques disponibles

```bash
# Métriques des nœuds
kubectl top nodes

# Métriques des pods
kubectl top pods

# Métriques détaillées
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
```

### 📊 Dashboard Kubernetes (optionnel)

Le script inclut le déploiement automatique du Kubernetes Dashboard pour une gestion visuelle du cluster.

### Déploiement automatique
```bash
./orchestrator.sh dashboard
```

**Ce qui se passe automatiquement :**
- ✅ Déploiement du Kubernetes Dashboard
- ✅ Création du compte admin avec les permissions nécessaires
- ✅ Génération du token d'accès (sauvegardé dans `dashboard-token.txt`)
- ✅ Copie du token dans le presse-papiers
- ✅ Lancement du proxy kubectl en arrière-plan
- ✅ Ouverture automatique dans votre navigateur par défaut

### Accès au Dashboard

Une fois le navigateur ouvert, **collez simplement le token** (Ctrl+V / Cmd+V) pour vous connecter.

Le token est disponible dans :
- Votre presse-papiers (copié automatiquement)
- Le fichier `dashboard-token.txt`

### Gestion du Dashboard
```bash
# Arrêter le proxy
./orchestrator.sh stop-dashboard

# Le dashboard est également proposé lors du démarrage
./orchestrator.sh start  # Répond "Y" pour inclure le dashboard
```

### Accès manuel (si nécessaire)
```bash
# 1. Démarrer le proxy
kubectl proxy

# 2. Accéder à l'URL
http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/

# 3. Utiliser le token du fichier dashboard-token.txt
cat dashboard-token.txt
```

> **Note :** Le proxy tourne en arrière-plan et s'arrête automatiquement avec `./orchestrator.sh stop` ou `./orchestrator.sh delete`

---

## 🔗 Technologies utilisées

| Technologie | Version | Rôle |
|-------------|---------|------|
| **K3s** | v1.28+ | Distribution Kubernetes légère |
| **Vagrant** | 2.2+ | Gestion des VMs |
| **VirtualBox** | 6.1+ | Hyperviseur |
| **PostgreSQL** | 15+ | Bases de données |
| **RabbitMQ** | 3.12+ | Message broker |
| **Docker** | 20.10+ | Conteneurisation |
| **kubectl** | 1.28+ | CLI Kubernetes |

---

## 📚 Ressources

- [Documentation Kubernetes](https://kubernetes.io/docs/)
- [Documentation K3s](https://docs.k3s.io/)
- [Documentation Vagrant](https://www.vagrantup.com/docs)
- [Best Practices Kubernetes](https://kubernetes.io/docs/concepts/configuration/overview/)

---

## 👥 Contributeurs

- 👤**sniang**: [Profile](https://learn.zone01dakar.sn/git/sniang)
- 👤**sdiene**: [Profile](https://learn.zone01dakar.sn/git/sdiene)

---

## 📝 Licence

Ce projet est à des fins éducatives uniquement.

---

## 🎓 Ce que vous avez appris

✅ Architecture microservices  
✅ Kubernetes (Deployments, StatefulSets, Services)  
✅ Gestion des secrets et ConfigMaps  
✅ Persistance de données (PVC/PV)  
✅ Autoscaling horizontal (HPA)  
✅ Infrastructure as Code (IaC)  
✅ Provisionnement avec Vagrant  
✅ Healthchecks et probes  
✅ Gestion de dépendances (initContainers)  

---