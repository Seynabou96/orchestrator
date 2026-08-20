"""
Configuration centralisée de l'application.

Toutes les variables d'environnement sont lues et validées ici,
une seule fois au démarrage. Si une variable requise est absente,
l'application refuse de démarrer avec un message clair.

Pourquoi une classe Config ?
- Séparer la configuration du code métier
- Permettre des configs différentes selon l'environnement
  (Config en prod, TestingConfig dans les tests)
- Un seul endroit à modifier si une variable change de nom

Pourquoi des variables atomiques (host, port, user, password, db) plutôt
qu'une seule INVENTORY_DB_URL composite ?
Une URL complète (postgresql://user:pass@host:port/db) mélange une
information sensible (le mot de passe) avec des informations non
sensibles (host, port, nom de la base). Dans Orchestrator (K3s), le
mot de passe doit aller dans un Secret et le host/port dans un ConfigMap
— ce qui est impossible si tout est fusionné dans une seule chaîne. En
gardant les variables séparées ici, l'app est déjà prête pour ce
découpage sans toucher au code Python plus tard.
"""

import os


class Config:
    """Configuration de production — lit les variables d'environnement."""

    DB_HOST: str = os.getenv("INVENTORY_DB_HOST", "")
    DB_PORT: str = os.getenv("INVENTORY_DB_PORT", "5432")
    DB_NAME: str = os.getenv("INVENTORY_DB_NAME", "")
    DB_USER: str = os.getenv("INVENTORY_DB_USER", "")
    DB_PASSWORD: str = os.getenv("INVENTORY_DB_PASSWORD", "")

    # Désactive le suivi des modifications SQLAlchemy (économie mémoire,
    # activé par défaut mais déprécié et inutile ici)
    SQLALCHEMY_TRACK_MODIFICATIONS: bool = False

    @classmethod
    def _build_database_uri(cls) -> str:
        """Reconstruit l'URL PostgreSQL à partir des variables atomiques."""
        return (
            f"postgresql://{cls.DB_USER}:{cls.DB_PASSWORD}"
            f"@{cls.DB_HOST}:{cls.DB_PORT}/{cls.DB_NAME}"
        )

    @classmethod
    def validate(cls) -> None:
        """
        Vérifie que toutes les variables requises sont présentes.
        Appelée au démarrage dans create_app().
        Lève une RuntimeError explicite plutôt que de crasher en plein traitement.
        """
        missing = []
        if not cls.DB_HOST:
            missing.append("INVENTORY_DB_HOST")
        if not cls.DB_NAME:
            missing.append("INVENTORY_DB_NAME")
        if not cls.DB_USER:
            missing.append("INVENTORY_DB_USER")
        if not cls.DB_PASSWORD:
            missing.append("INVENTORY_DB_PASSWORD")
        if missing:
            raise RuntimeError(
                f"Variables d'environnement manquantes : {', '.join(missing)}\n"
                "Exemple :\n"
                "INVENTORY_DB_HOST=inventory-db\n"
                "INVENTORY_DB_PORT=5432\n"
                "INVENTORY_DB_NAME=movies_db\n"
                "INVENTORY_DB_USER=inv_user\n"
                "INVENTORY_DB_PASSWORD=password"
            )
        # SQLALCHEMY_DATABASE_URI est construit ici, après validation,
        # pour ne jamais assembler une URL avec des champs vides.
        cls.SQLALCHEMY_DATABASE_URI = cls._build_database_uri()


class TestingConfig(Config):
    """
    Configuration pour les tests unitaires.

    Remplace PostgreSQL par SQLite en mémoire :
    - Pas besoin d'une vraie base de données
    - Chaque test repart d'une base vide
    - Les tests tournent sans infrastructure

    TESTING=True désactive la propagation d'erreurs Flask
    pour que pytest récupère les vraies exceptions.
    """

    SQLALCHEMY_DATABASE_URI: str = "sqlite://"
    TESTING: bool = True

    @classmethod
    def validate(cls) -> None:
        # Pas de validation en mode test : SQLite ne nécessite
        # aucune variable d'environnement. SQLALCHEMY_DATABASE_URI
        # reste la valeur de classe fixée ci-dessus.
        pass
