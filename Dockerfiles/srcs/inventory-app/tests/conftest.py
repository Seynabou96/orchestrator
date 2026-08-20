"""
conftest.py — fixtures partagées entre tous les fichiers de tests.

pytest charge automatiquement ce fichier avant d'exécuter les tests.
Les fixtures définies ici sont disponibles dans tous les tests du dossier
sans import explicite.

Fixtures :
    app     : instance Flask configurée pour les tests (SQLite en mémoire)
    client  : client HTTP de test Flask, pour simuler des requêtes
    db_session : session SQLAlchemy dans le contexte de l'app de test
"""

import pytest

from app import create_app
from app.config import TestingConfig
from app.extensions import db as _db


@pytest.fixture(scope="session")
def app():
    """
    Crée une instance de l'application Flask pour toute la session de tests.

    scope="session" : la même instance est réutilisée pour tous les tests.
    La base SQLite en mémoire est créée une seule fois.
    """
    application = create_app(TestingConfig)
    return application


@pytest.fixture(scope="function")
def client(app):
    """
    Client HTTP de test Flask.

    scope="function" : un nouveau client par fonction de test.
    app.test_client() simule des requêtes HTTP sans démarrer un vrai serveur.
    """
    return app.test_client()


@pytest.fixture(scope="function", autouse=True)
def clean_db(app):
    """
    Vide les tables avant chaque test.

    autouse=True : appliqué automatiquement à chaque test sans
    avoir à le déclarer explicitement.

    Pourquoi nettoyer plutôt que recréer ?
    Recréer la base à chaque test (drop_all + create_all) est lent.
    Supprimer les lignes est instantané avec SQLite en mémoire.
    """
    with app.app_context():
        _db.session.query(__import__('app.models.movie', fromlist=['Movie']).Movie).delete()
        _db.session.commit()
    yield
