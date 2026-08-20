"""
Configuration de l'api-gateway.

La gateway a besoin de deux destinations :
- inventory-app (HTTP) : pour forwarder les requêtes /api/movies
- RabbitMQ (AMQP) : pour publier dans billing_queue

Convention de nommage des variables d'environnement, cohérente sur les
3 services pour faciliter un futur mapping Helm/Kustomize (Orchestrator) :
    <SERVICE>_<RESSOURCE>_<CHAMP>
Exemples : INVENTORY_DB_HOST (la base de données d'inventory-app),
INVENTORY_APP_HOST (le service HTTP inventory-app lui-même — utilisé ici
par la gateway pour le joindre). Le suffixe _APP_ distingue explicitement
"le service applicatif lui-même" de "sa base de données", pour qu'un
template Helm générique du type {{ .service }}_DB_HOST ne se confonde
jamais avec l'adresse du service HTTP.

Variables atomiques (host + port séparés) plutôt qu'une URL composite
INVENTORY_API_URL : permet de mapper INVENTORY_APP_HOST directement sur
un nom de Service K8s (ConfigMap) sans avoir à parser une URL plus tard.
Même logique déjà appliquée à RabbitMQ (host/port/user/password séparés).

Aucune valeur par défaut sur les credentials RabbitMQ : un défaut silencieux
("user"/"password") peut masquer un .env mal renseigné et provoquer une
erreur d'authentification difficile à diagnostiquer (vu sur le projet
précédent). On préfère échouer fort au démarrage via validate().
"""

import os


class Config:
    INVENTORY_APP_HOST: str = os.getenv("INVENTORY_APP_HOST", "")
    INVENTORY_APP_PORT: str = os.getenv("INVENTORY_APP_PORT", "8080")

    RABBITMQ_HOST: str = os.getenv("RABBITMQ_HOST", "")
    RABBITMQ_PORT: int = int(os.getenv("RABBITMQ_PORT", "5672"))
    RABBITMQ_USER: str = os.getenv("RABBITMQ_USER", "")
    RABBITMQ_PASSWORD: str = os.getenv("RABBITMQ_PASSWORD", "")

    @classmethod
    def _build_inventory_api_url(cls) -> str:
        return f"http://{cls.INVENTORY_APP_HOST}:{cls.INVENTORY_APP_PORT}"

    @classmethod
    def validate(cls) -> None:
        missing = []
        if not cls.INVENTORY_APP_HOST:
            missing.append("INVENTORY_APP_HOST")
        if not cls.RABBITMQ_HOST:
            missing.append("RABBITMQ_HOST")
        if not cls.RABBITMQ_USER:
            missing.append("RABBITMQ_USER")
        if not cls.RABBITMQ_PASSWORD:
            missing.append("RABBITMQ_PASSWORD")
        if missing:
            raise RuntimeError(
                f"Variables d'environnement manquantes : {', '.join(missing)}\n"
                "Exemple :\n"
                "INVENTORY_APP_HOST=inventory-app\n"
                "INVENTORY_APP_PORT=8080\n"
                "RABBITMQ_HOST=rabbit-queue\n"
                "RABBITMQ_PORT=5672\n"
                "RABBITMQ_USER=<défini dans .env>\n"
                "RABBITMQ_PASSWORD=<défini dans .env>"
            )
        # Construit après validation, jamais avec un host vide.
        cls.INVENTORY_API_URL = cls._build_inventory_api_url()


class TestingConfig(Config):
    """
    Config de test.
    Les appels HTTP vers inventory et pika sont mockés dans les tests,
    donc les URLs n'ont pas besoin d'être valides — mais on garde des
    valeurs explicites pour que TestingConfig ne dépende jamais du .env.
    """
    INVENTORY_APP_HOST: str = "inventory-mock"
    INVENTORY_APP_PORT: str = "8080"
    INVENTORY_API_URL: str = "http://inventory-mock:8080"
    RABBITMQ_HOST: str = "rabbitmq-mock"
    RABBITMQ_PORT: int = 5672
    RABBITMQ_USER: str = "test_user"
    RABBITMQ_PASSWORD: str = "test_password"
    TESTING: bool = True

    @classmethod
    def validate(cls) -> None:
        pass
