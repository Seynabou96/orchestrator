#!/bin/bash

set -e

# Couleurs
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo "Déploiement de tous les services"
echo -e "==========================================${NC}\n"

# Fonction pour nettoyer un service
cleanup_service() {
    local service_name=$1
    echo -e "${YELLOW}Nettoyage de ${service_name}...${NC}"
    kubectl delete statefulset ${service_name} -n default --ignore-not-found=true
    kubectl delete pvc ${service_name}-data-${service_name}-0 -n default --ignore-not-found=true
    echo -e "${GREEN}✓ ${service_name} nettoyé${NC}\n"
}

# Fonction pour déployer un service
deploy_service() {
    local service_name=$1
    local secret_file=$2
    local statefulset_file=$3
    
    echo -e "${BLUE}==========================================\n"
    echo -e "Déploiement de ${service_name}${NC}"
    echo -e "${BLUE}==========================================${NC}\n"
    
    # Créer le secret
    echo -e "${YELLOW}[1/3] Création du Secret...${NC}"
    kubectl apply -f ${secret_file}
    echo -e "${GREEN}✓ Secret créé${NC}\n"
    
    # Déployer le StatefulSet
    echo -e "${YELLOW}[2/3] Déploiement du StatefulSet...${NC}"
    kubectl apply -f ${statefulset_file}
    echo -e "${GREEN}✓ StatefulSet déployé${NC}\n"
    
    # Attendre que le pod soit prêt
    echo -e "${YELLOW}[3/3] Attente du démarrage (timeout 180s)...${NC}"
    if kubectl wait --for=condition=ready pod/${service_name}-0 -n default --timeout=180s; then
        echo -e "${GREEN}✓ ${service_name}-0 est prêt!${NC}\n"
        return 0
    else
        echo -e "${RED}✗ ${service_name}-0 n'a pas démarré${NC}"
        echo -e "\n${YELLOW}Logs:${NC}"
        kubectl logs ${service_name}-0 -n default 2>&1 | tail -30
        echo -e "\n${YELLOW}Events:${NC}"
        kubectl get events -n default --field-selector involvedObject.name=${service_name}-0 --sort-by='.lastTimestamp' | tail -10
        return 1
    fi
}

# Fonction pour tester une base de données PostgreSQL
test_postgres() {
    local db_name=$1
    local db_user=$2
    local db_database=$3
    
    echo -e "${BLUE}==========================================\n"
    echo -e "Tests de ${db_name}${NC}"
    echo -e "${BLUE}==========================================${NC}\n"
    
    echo -e "${YELLOW}Test 1: Disponibilité PostgreSQL...${NC}"
    if kubectl exec ${db_name}-0 -n default -- pg_isready -U ${db_user}; then
        echo -e "${GREEN}✓ PostgreSQL disponible${NC}\n"
    else
        echo -e "${RED}✗ PostgreSQL non disponible${NC}\n"
        return 1
    fi
    
    echo -e "${YELLOW}Test 2: Version PostgreSQL...${NC}"
    kubectl exec ${db_name}-0 -n default -- psql -U ${db_user} -d ${db_database} -c "SELECT version();" | head -3
    echo -e "${GREEN}✓ Connexion réussie${NC}\n"
    
    echo -e "${YELLOW}Test 3: Création d'une table de test...${NC}"
    kubectl exec ${db_name}-0 -n default -- psql -U ${db_user} -d ${db_database} <<EOF
CREATE TABLE IF NOT EXISTS health_check (
    id SERIAL PRIMARY KEY,
    check_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status VARCHAR(50)
);
INSERT INTO health_check (status) VALUES ('OK');
SELECT * FROM health_check;
EOF
    echo -e "${GREEN}✓ Table créée et testée${NC}\n"
}

# Fonction pour tester RabbitMQ
test_rabbitmq() {
    echo -e "${BLUE}==========================================\n"
    echo -e "Tests de RabbitMQ${NC}"
    echo -e "${BLUE}==========================================${NC}\n"
    
    echo -e "${YELLOW}Test 1: Statut RabbitMQ...${NC}"
    if kubectl exec rabbitmq-0 -n default -- rabbitmq-diagnostics -q ping; then
        echo -e "${GREEN}✓ RabbitMQ répond${NC}\n"
    else
        echo -e "${RED}✗ RabbitMQ ne répond pas${NC}\n"
        return 1
    fi
    
    echo -e "${YELLOW}Test 2: Liste des vhosts...${NC}"
    kubectl exec rabbitmq-0 -n default -- rabbitmqctl list_vhosts
    echo -e "${GREEN}✓ Vhosts listés${NC}\n"
    
    echo -e "${YELLOW}Test 3: Liste des utilisateurs...${NC}"
    kubectl exec rabbitmq-0 -n default -- rabbitmqctl list_users
    echo -e "${GREEN}✓ Utilisateurs listés${NC}\n"
    
    echo -e "${YELLOW}Test 4: Accès Management UI...${NC}"
    echo "Management UI accessible sur: http://$(kubectl get pod rabbitmq-0 -n default -o jsonpath='{.status.podIP}'):15672"
    echo "Username: admin"
    echo "Password: (dans le secret rabbitmq-secret)"
    echo -e "${GREEN}✓ Management UI disponible${NC}\n"
}

# Étape 1: Nettoyage
echo -e "${BLUE}==========================================\n"
echo -e "Nettoyage des ressources existantes${NC}"
echo -e "${BLUE}==========================================${NC}\n"

cleanup_service "billing-db"
cleanup_service "inventory-db"
cleanup_service "rabbitmq"

echo -e "${YELLOW}Attente de 5 secondes...${NC}\n"
sleep 5

# Étape 2: Déploiement
BILLING_SUCCESS=false
INVENTORY_SUCCESS=false
RABBITMQ_SUCCESS=false

if deploy_service "billing-db" "Manifests/billing-db-secret.yaml" "Manifests/billing-database-statefulset.yaml"; then
    BILLING_SUCCESS=true
fi

sleep 2

if deploy_service "inventory-db" "Manifests/inventory-db-secret.yaml" "Manifests/inventory-database-statefulset.yaml"; then
    INVENTORY_SUCCESS=true
fi

sleep 2

if deploy_service "rabbitmq" "Manifests/rabbitmq-secret.yaml" "Manifests/rabbitmq-statefulset.yaml"; then
    RABBITMQ_SUCCESS=true
fi

# Étape 3: Tests
echo -e "\n${BLUE}==========================================\n"
echo -e "Exécution des tests${NC}"
echo -e "${BLUE}==========================================${NC}\n"

if [ "$BILLING_SUCCESS" = true ]; then
    test_postgres "billing-db" "billing_user" "billing_db" || echo -e "${RED}Tests billing-db échoués${NC}\n"
fi

if [ "$INVENTORY_SUCCESS" = true ]; then
    test_postgres "inventory-db" "inventory_user" "inventory_db" || echo -e "${RED}Tests inventory-db échoués${NC}\n"
fi

if [ "$RABBITMQ_SUCCESS" = true ]; then
    test_rabbitmq || echo -e "${RED}Tests RabbitMQ échoués${NC}\n"
fi

# Résumé final
echo -e "\n${BLUE}=========================================="
echo -e "Résumé du déploiement${NC}"
echo -e "${BLUE}==========================================${NC}\n"

kubectl get statefulset -n default
echo ""
kubectl get pods -n default -l 'app in (billing-db,inventory-db,rabbitmq)'
echo ""
kubectl get pvc -n default
echo ""
kubectl get svc -n default -l 'app in (billing-db,inventory-db,rabbitmq)'

echo -e "\n${BLUE}=========================================="
echo -e "Informations de connexion${NC}"
echo -e "${BLUE}==========================================${NC}"
echo -e "
${YELLOW}Billing Database:${NC}
  Service: billing-db.default.svc.cluster.local:5432
  Database: billing_db
  User: billing_user

${YELLOW}Inventory Database:${NC}
  Service: inventory-db.default.svc.cluster.local:5432
  Database: inventory_db
  User: inventory_user

${YELLOW}RabbitMQ:${NC}
  Service AMQP: rabbitmq.default.svc.cluster.local:5672
  Service Management: rabbitmq.default.svc.cluster.local:15672
  User: admin
  Management UI: http://<pod-ip>:15672
"

echo -e "${BLUE}=========================================="
echo -e "Commandes utiles${NC}"
echo -e "${BLUE}==========================================${NC}"
echo -e "
${YELLOW}# Connexion billing-db:${NC}
kubectl exec -it billing-db-0 -n default -- psql -U billing_user -d billing_db

${YELLOW}# Connexion inventory-db:${NC}
kubectl exec -it inventory-db-0 -n default -- psql -U inventory_user -d inventory_db

${YELLOW}# Connexion RabbitMQ:${NC}
kubectl exec -it rabbitmq-0 -n default -- rabbitmqctl status

${YELLOW}# Logs:${NC}
kubectl logs -f billing-db-0 -n default
kubectl logs -f inventory-db-0 -n default
kubectl logs -f rabbitmq-0 -n default

${YELLOW}# Port-forward Management UI RabbitMQ:${NC}
kubectl port-forward rabbitmq-0 15672:15672 -n default
# Puis accéder à http://localhost:15672

${YELLOW}# Redémarrer:${NC}
kubectl rollout restart statefulset/billing-db -n default
kubectl rollout restart statefulset/inventory-db -n default
kubectl rollout restart statefulset/rabbitmq -n default
"

if [ "$BILLING_SUCCESS" = true ] && [ "$INVENTORY_SUCCESS" = true ] && [ "$RABBITMQ_SUCCESS" = true ]; then
    echo -e "${GREEN}✓ Tous les services sont déployés avec succès!${NC}\n"
    exit 0
else
    echo -e "${RED}✗ Certains services ont échoué${NC}\n"
    exit 1
fi