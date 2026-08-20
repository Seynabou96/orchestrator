"""
Configuration de billing-app.

Deux services distincts ont besoin de leur propre connexion :
- PostgreSQL : pour persister les ordres
- RabbitMQ   : pour consommer les messages de billing_queue

Variables atomiques plutôt que des URLs composites (BILLING_DB_URL,
RABBITMQ_URL) : un mot de passe mélangé dans une URL complète ne peut
pas être séparé proprement en Secret K8s d'un côté et ConfigMap de
l'autre (host, port, nom de service). En gardant host/port/user/password
séparés, billing_consumer.py reçoit toujours une RABBITMQ_URL/
SQLALCHEMY_DATABASE_URI complète via flask_app.config — seule la manière
de la construire change, pas son usage en aval (aucune modification dans
billing_consumer.py).

La validation est stricte : si une variable manque, le service refuse
de démarrer. Mieux vaut un crash explicite au démarrage qu'un
comportement silencieux en production.
"""

import os


class Config:
    DB_HOST: str = os.getenv("BILLING_DB_HOST", "")
    DB_PORT: str = os.getenv("BILLING_DB_PORT", "5432")
    DB_NAME: str = os.getenv("BILLING_DB_NAME", "")
    DB_USER: str = os.getenv("BILLING_DB_USER", "")
    DB_PASSWORD: str = os.getenv("BILLING_DB_PASSWORD", "")

    RABBITMQ_HOST: str = os.getenv("RABBITMQ_HOST", "")
    RABBITMQ_PORT: str = os.getenv("RABBITMQ_PORT", "5672")
    RABBITMQ_USER: str = os.getenv("RABBITMQ_USER", "")
    RABBITMQ_PASSWORD: str = os.getenv("RABBITMQ_PASSWORD", "")

    SQLALCHEMY_TRACK_MODIFICATIONS: bool = False

    @classmethod
    def _build_database_uri(cls) -> str:
        return (
            f"postgresql://{cls.DB_USER}:{cls.DB_PASSWORD}"
            f"@{cls.DB_HOST}:{cls.DB_PORT}/{cls.DB_NAME}"
        )

    @classmethod
    def _build_rabbitmq_url(cls) -> str:
        return (
            f"amqp://{cls.RABBITMQ_USER}:{cls.RABBITMQ_PASSWORD}"
            f"@{cls.RABBITMQ_HOST}:{cls.RABBITMQ_PORT}/"
        )

    @classmethod
    def validate(cls) -> None:
        missing = []
        if not cls.DB_HOST:
            missing.append("BILLING_DB_HOST")
        if not cls.DB_NAME:
            missing.append("BILLING_DB_NAME")
        if not cls.DB_USER:
            missing.append("BILLING_DB_USER")
        if not cls.DB_PASSWORD:
            missing.append("BILLING_DB_PASSWORD")
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
                "BILLING_DB_HOST=billing-db\n"
                "BILLING_DB_PORT=5432\n"
                "BILLING_DB_NAME=billing_db\n"
                "BILLING_DB_USER=billing_user\n"
                "BILLING_DB_PASSWORD=password\n"
                "RABBITMQ_HOST=rabbit-queue\n"
                "RABBITMQ_PORT=5672\n"
                "RABBITMQ_USER=mq_user\n"
                "RABBITMQ_PASSWORD=password"
            )
        # Construits après validation, jamais avec des champs vides.
        cls.SQLALCHEMY_DATABASE_URI = cls._build_database_uri()
        cls.RABBITMQ_URL = cls._build_rabbitmq_url()


class TestingConfig(Config):
    """
    Config de test : SQLite en mémoire, URL RabbitMQ factice.
    Le consumer RabbitMQ est mocké dans les tests — pas besoin
    d'un vrai broker pour tester la logique métier.
    """
    SQLALCHEMY_DATABASE_URI: str = "sqlite://"
    RABBITMQ_URL: str = "amqp://guest:guest@localhost:5672/"
    TESTING: bool = True

    @classmethod
    def validate(cls) -> None:
        # Pas de validation en mode test. SQLALCHEMY_DATABASE_URI et
        # RABBITMQ_URL restent les valeurs de classe fixées ci-dessus.
        pass
