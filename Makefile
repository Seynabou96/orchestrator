# =============================================================================
# Makefile — Orchestrator (remplace orchestrator.sh)
#
# Reprend la même grammaire de commandes que l'ancien orchestrator.sh
# (create, start, stop, delete, status, dashboard), mais pilote Helm
# (3 charts indépendants : inventory, billing, api-gateway) plutôt que
# des kubectl apply -f à plat sur des manifests non templatés.
#
# Ordre d'installation imposé par les dépendances réelles (pas un choix
# arbitraire) :
#   1. inventory  — aucune dépendance externe
#   2. billing    — aucune dépendance externe (DB + RabbitMQ + app)
#   3. api-gateway — dépend de inventory-app ET de rabbitmq (billing),
#                    cross-namespace — doit donc être installé en dernier
#
# Usage :
#   make create     -> crée les VMs (Vagrant) + CNI Cilium + Sealed Secrets
#   make seal       -> génère les SealedSecret (1 fois, ou après rotation)
#   make start      -> helm install/upgrade des 3 charts dans l'ordre
#   make status     -> état du cluster + des releases Helm
#   make stop       -> helm uninstall des 3 charts (sans détruire les VMs)
#   make delete     -> détruit complètement les VMs (vagrant destroy)
#   make dashboard  -> déploie + ouvre le Kubernetes Dashboard
# =============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# Namespaces (doivent rester cohérents avec charts/*/values.yaml)
NS_INVENTORY := inventory
NS_BILLING   := billing
NS_GATEWAY   := api-gateway

# Couleurs (mêmes conventions que l'ancien orchestrator.sh)
GREEN  := \033[0;32m
RED    := \033[0;31m
YELLOW := \033[1;33m
BLUE   := \033[0;34m
NC     := \033[0m

define log_info
	@echo -e "$(GREEN)[INFO]$(NC) $(1)"
endef
define log_step
	@echo -e "$(BLUE)[STEP]$(NC) $(1)"
endef
define log_warn
	@echo -e "$(YELLOW)[WARN]$(NC) $(1)"
endef

.PHONY: help create start stop delete status seal dashboard stop-dashboard \
        helm-deps lint template test-smoke debug \
        argocd argocd-ui argocd-sync argocd-status argocd-delete

help:
	@echo "Cibles disponibles :"
	@echo "  make create        - Crée les VMs (master+agent), installe Cilium + Sealed Secrets"
	@echo "  make seal          - Génère les SealedSecret (interactif, mots de passe)"
	@echo "  make helm-deps     - Télécharge les dépendances Helm (kube-prometheus-stack)"
	@echo "  make start         - Déploie les 4 charts Helm dans l'ordre (sans ArgoCD)"
	@echo "  make status        - État des nœuds, pods, releases Helm"
	@echo "  make stop          - Désinstalle les 4 releases Helm (garde les VMs et le cluster)"
	@echo "  make delete        - Détruit complètement les VMs (vagrant destroy)"
	@echo "  make dashboard     - Déploie et ouvre le Kubernetes Dashboard"
	@echo "  make lint          - helm lint sur les charts"
	@echo "  make template      - helm template (dry-run) sur les charts, pour relecture avant apply"
	@echo "  make debug         - Commandes de debug Helm utiles (history, values, manifest)"
	@echo "  make test-smoke    - Health check + flux inventory/billing via api-gateway"
	@echo "  --- ArgoCD (complément à make start, pas un remplacement) ---"
	@echo "  make argocd        - Installe ArgoCD + déploie l'ApplicationSet"
	@echo "  make argocd-ui     - Ouvre l'UI ArgoCD (port-forward 8080)"
	@echo "  make argocd-sync   - Déclenche un sync manuel sur toutes les Applications"
	@echo "  make argocd-status - État de toutes les Applications ArgoCD"
	@echo "  make argocd-delete - Désinstalle ArgoCD du cluster"

# -----------------------------------------------------------------------------
# create : VMs + CNI + Sealed Secrets controller. Équivalent de l'ancien
# "orchestrator.sh create", mais inclut maintenant Cilium et Sealed
# Secrets (absents de l'ancien script, ajoutés comme partie de
# l'optimisation, pas comme étape facultative).
# -----------------------------------------------------------------------------
create:
	$(call log_step,=== CRÉATION DU CLUSTER (Vagrant + K3s) ===)
	vagrant up
	$(call log_step,=== CONFIGURATION DE KUBECTL ===)
	bash Scripts/setup-kubectl.sh
	$(call log_step,=== INSTALLATION CILIUM + SEALED SECRETS (Helm) ===)
	bash Scripts/install-cluster-tools.sh
	$(call log_info,Cluster créé. Lancez 'make seal' puis 'make start'.)

# -----------------------------------------------------------------------------
# seal : génère les 4 SealedSecret (inventory-db, billing-db, rabbitmq
# x2). À lancer une fois après 'make create', ou après une rotation de
# mot de passe.
# -----------------------------------------------------------------------------
seal:
	$(call log_step,=== GÉNÉRATION DES SEALEDSECRET ===)
	bash Scripts/seal-secrets.sh

# -----------------------------------------------------------------------------
# helm-deps : télécharge la dépendance kube-prometheus-stack déclarée
# dans charts/monitoring/Chart.yaml. À lancer avant le premier
# 'make start' (ou après toute modif de Chart.yaml) — sans ça,
# 'helm install monitoring' échoue avec "found in Chart.yaml, but
# missing in charts/ directory".
# -----------------------------------------------------------------------------
helm-deps:
	$(call log_step,=== TÉLÉCHARGEMENT DES DÉPENDANCES HELM (monitoring) ===)
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
	helm repo update
	helm dependency update ./charts/monitoring

# -----------------------------------------------------------------------------
# lint / template : validations Helm avant un vrai déploiement.
# -----------------------------------------------------------------------------
lint:
	$(call log_step,=== HELM LINT (4 charts) ===)
	helm lint ./charts/inventory
	helm lint ./charts/billing
	helm lint ./charts/api-gateway
	helm lint ./charts/monitoring

template:
	$(call log_step,=== HELM TEMPLATE (dry-run, 4 charts) ===)
	@echo "--- inventory ---"
	helm template inventory ./charts/inventory
	@echo "--- billing ---"
	helm template billing ./charts/billing
	@echo "--- api-gateway ---"
	helm template api-gateway ./charts/api-gateway
	@echo "--- monitoring ---"
	helm template monitoring ./charts/monitoring

# -----------------------------------------------------------------------------
# start : déploie les 3 charts dans l'ORDRE imposé par les dépendances
# réelles. "helm upgrade --install" est idempotent : relancer "make
# start" après un "make create" déjà fait met juste à jour les releases
# existantes, ne les recrée pas inutilement.
# -----------------------------------------------------------------------------
start:
	$(call log_step,=== DÉPLOIEMENT — 1/4 : inventory (aucune dépendance) ===)
	helm upgrade --install inventory ./charts/inventory --create-namespace
	$(call log_step,=== DÉPLOIEMENT — 2/4 : billing (aucune dépendance) ===)
	helm upgrade --install billing ./charts/billing --create-namespace
	$(call log_step,=== DÉPLOIEMENT — 3/4 : api-gateway (dépend de inventory + billing) ===)
	helm upgrade --install api-gateway ./charts/api-gateway --create-namespace
	$(call log_step,=== DÉPLOIEMENT — 4/4 : monitoring (Prometheus + Grafana) ===)
	helm upgrade --install monitoring ./charts/monitoring --namespace monitoring --create-namespace
	$(call log_info,Les 4 charts sont déployés. 'make status' pour vérifier l'état des pods.)
	$(call log_warn,Les pods peuvent prendre 1-3 minutes à devenir Ready (initContainers d'attente).)
	$(call log_info,Grafana : kubectl port-forward -n monitoring svc/monitoring-grafana 3001:80  — PAS 3000, déjà pris par api-gateway)

# -----------------------------------------------------------------------------
# status : équivalent de l'ancien "orchestrator.sh status", étendu aux
# 3 namespaces et aux releases Helm.
# -----------------------------------------------------------------------------
status:
	$(call log_step,=== NŒUDS ===)
	-kubectl get nodes -o wide
	$(call log_step,=== RELEASES HELM ===)
	-helm list --all-namespaces
	$(call log_step,=== PODS — inventory ===)
	-kubectl get pods -n $(NS_INVENTORY) -o wide
	$(call log_step,=== PODS — billing ===)
	-kubectl get pods -n $(NS_BILLING) -o wide
	$(call log_step,=== PODS — api-gateway ===)
	-kubectl get pods -n $(NS_GATEWAY) -o wide
	$(call log_step,=== PODS — monitoring ===)
	-kubectl get pods -n monitoring -o wide
	$(call log_step,=== INGRESS ===)
	-kubectl get ingress -n $(NS_GATEWAY)
	$(call log_step,=== HPA — inventory ===)
	-kubectl get hpa -n $(NS_INVENTORY)
	$(call log_step,=== HPA — api-gateway ===)
	-kubectl get hpa -n $(NS_GATEWAY)

# -----------------------------------------------------------------------------
# stop : désinstalle les releases Helm SANS détruire les VMs ni le
# cluster K3s — équivalent "arrêt applicatif", pas "arrêt machine".
# Ordre inverse de start (api-gateway dépend des autres, donc on le
# retire en premier pour éviter des erreurs de connexion résiduelles
# dans les logs, même si ça n'empêche pas techniquement l'uninstall).
# -----------------------------------------------------------------------------
stop:
	$(call log_step,=== DÉSINSTALLATION DES RELEASES HELM ===)
	-helm uninstall monitoring -n monitoring
	-helm uninstall api-gateway
	-helm uninstall billing
	-helm uninstall inventory
	$(call log_info,Releases désinstallées. Les VMs et le cluster K3s restent actifs.)
	$(call log_info,Pour tout arrêter : utilisez 'vagrant halt' (pas 'make delete', qui détruit).)

# -----------------------------------------------------------------------------
# delete : destruction complète des VMs (équivalent "orchestrator.sh
# delete").
# -----------------------------------------------------------------------------
delete:
	$(call log_warn,Cette commande détruit complètement les VMs (vagrant destroy -f).)
	vagrant destroy -f

# -----------------------------------------------------------------------------
# dashboard : reprend la logique de deploy_dashboard() de l'ancien
# orchestrator.sh.
# -----------------------------------------------------------------------------
dashboard:
	$(call log_step,=== DÉPLOIEMENT DU KUBERNETES DASHBOARD ===)
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
	kubectl wait --for=condition=ready pod -l k8s-app=kubernetes-dashboard -n kubernetes-dashboard --timeout=180s || true
	bash Scripts/setup-dashboard-admin.sh

stop-dashboard:
	$(call log_step,=== ARRÊT DU PROXY DASHBOARD ===)
	-pkill -f "kubectl proxy" || true

# -----------------------------------------------------------------------------
# debug : commandes Helm utiles pour diagnostiquer une release sans
# toucher au cluster. "template" et "lint" existent déjà au-dessus —
# ici ce sont des commandes sur des releases DÉJÀ installées (history,
# valeurs effectives, manifest réellement appliqué).
# -----------------------------------------------------------------------------
debug:
	$(call log_step,=== HISTORIQUE DES RELEASES ===)
	-helm history inventory
	-helm history billing
	-helm history api-gateway
	-helm history monitoring -n monitoring
	$(call log_step,=== VALEURS EFFECTIVES (après merge values.yaml) — inventory ===)
	-helm get values inventory
	$(call log_step,=== MANIFEST RÉELLEMENT APPLIQUÉ — inventory ===)
	-helm get manifest inventory
	$(call log_info,Pour un service précis : helm get values|manifest|notes <release> [-n <namespace>])
	$(call log_info,Pour voir les events d'un pod en erreur : kubectl describe pod <pod> -n <namespace>)
	$(call log_info,Pour les logs d'un initContainer bloqué : kubectl logs <pod> -c <init-container-name> -n <namespace>)

# -----------------------------------------------------------------------------
# test-smoke : reprend l'esprit de play-with-containers/Makefile
# (test-smoke) — seul api-gateway est interrogé directement, exactement
# comme en Compose où seul ce service est exposé à l'hôte. Sur K8s,
# l'exposition se fait via kubectl port-forward plutôt que via un port
# mappé sur l'hôte (pas le même mécanisme, mais le même principe :
# inventory-app et billing-app restent injoignables depuis l'extérieur,
# leur bon fonctionnement se vérifie À TRAVERS la gateway).
#
# Nécessite que 'make start' ait déjà tourné et que les pods soient
# Ready (vérifier avec 'make status' avant de lancer ce test).
# -----------------------------------------------------------------------------
test-smoke:
	$(call log_step,=== TEST SMOKE (port-forward + flux inventory/billing) ===)
	@bash -c '\
	if [ -f /tmp/pf-gateway.pid ]; then \
		OLD_PID=$$(cat /tmp/pf-gateway.pid); \
		kill "$$OLD_PID" 2>/dev/null; \
		rm -f /tmp/pf-gateway.pid; \
	fi; \
	sleep 1; \
	kubectl port-forward -n $(NS_GATEWAY) svc/api-gateway-service 3000:3000 &>/tmp/pf-gateway.log & \
	PF_PID=$$!; \
	echo "$$PF_PID" > /tmp/pf-gateway.pid; \
	sleep 3; \
	echo "=== Health check (gateway uniquement — seul service exposé) ==="; \
	curl -sf http://localhost:3000/health && echo " [gateway OK]" || echo " [GATEWAY DOWN]"; \
	echo ""; \
	echo "=== Flux inventory (via gateway) ==="; \
	curl -s -X POST http://localhost:3000/api/movies \
		-H "Content-Type: application/json" \
		-d "{\"title\": \"Helm Test\", \"description\": \"Teste via kubectl port-forward\"}"; \
	echo ""; \
	curl -s http://localhost:3000/api/movies; \
	echo ""; \
	echo "=== Flux billing (via gateway) ==="; \
	curl -s -i -X POST http://localhost:3000/api/billing \
		-H "Content-Type: application/json" \
		-d "{\"user_id\": \"1\", \"number_of_items\": \"3\", \"total_amount\": \"45\"}"; \
	echo ""; \
	echo "Attente du traitement RabbitMQ (3s)..."; \
	sleep 3; \
	echo "=== Vérification de l'\''insertion réelle en base billing ==="; \
	kubectl exec -n $(NS_BILLING) billing-database-0 -- \
		psql -U billing_user -d billing_db -c "SELECT * FROM orders;"; \
	kill $$PF_PID 2>/dev/null; \
	rm -f /tmp/pf-gateway.pid; \
	echo "Port-forward arrêté."; \
	'

# =============================================================================
# ArgoCD — complément à make start, pas un remplacement.
# make start (Helm direct) reste la méthode de déploiement principale.
# ArgoCD ajoute la synchronisation GitOps (détecte les diffs entre le
# repo GitHub et l'état réel du cluster, applique sur demande manuelle).
# =============================================================================

argocd:
	$(call log_step,=== INSTALLATION D'ARGOCD + APPLICATIONSET ===)
	bash Scripts/install-argocd.sh

argocd-ui:
	$(call log_step,=== OUVERTURE DE L'UI ARGOCD ===)
	$(call log_info,Mot de passe admin : $$(cat ./argocd/.argocd-admin-password 2>/dev/null || echo 'fichier non trouvé — lancer make argocd d'\''abord'))
	$(call log_info,URL : http://localhost:8080 — login : admin)
	$(call log_warn,Port 8080 — pas de conflit avec api-gateway (3000) ni Grafana (3001))
	kubectl port-forward -n argocd svc/argocd-server 8080:443

argocd-sync:
	$(call log_step,=== SYNC MANUEL — TOUTES LES APPLICATIONS ARGOCD ===)
	$(call log_warn,Le sync applique les charts depuis GitHub vers le cluster — s'\''assurer que le repo est à jour.)
	argocd app list --server localhost:8080 --insecure --plaintext 2>/dev/null || \
		kubectl port-forward -n argocd svc/argocd-server 8080:443 &>/tmp/pf-argocd.log & \
		sleep 3
	argocd login localhost:8080 \
		--username admin \
		--password "$$(cat ./argocd/.argocd-admin-password)" \
		--insecure
	argocd app sync -l app.kubernetes.io/instance=orchestrator --insecure

argocd-status:
	$(call log_step,=== ÉTAT DES APPLICATIONS ARGOCD ===)
	-kubectl get applications -n argocd -o wide
	-kubectl get applicationsets -n argocd

argocd-delete:
	$(call log_warn,Suppression d'ArgoCD — les releases Helm restent intactes dans le cluster.)
	-kubectl delete applicationset orchestrator -n argocd
	-kubectl delete -n argocd \
		-f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.4/manifests/install.yaml \
		--ignore-not-found
	-kubectl delete namespace argocd --ignore-not-found
	$(call log_info,ArgoCD supprimé. Les charts Helm (inventory/billing/api-gateway/monitoring) restent déployés.)
