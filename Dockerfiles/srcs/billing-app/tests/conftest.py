"""
Fixtures partagées pour les tests billing-app.

Le consumer RabbitMQ n'est PAS démarré dans les tests.
On teste uniquement la logique du callback (validation + insertion DB)
en simulant ce que RabbitMQ ferait : appeler le callback avec
un channel mocké, une méthode mockée et un body en bytes.
"""

import pytest
from unittest.mock import MagicMock

from app import create_app
from app.config import TestingConfig
from app.extensions import db as _db
from app.models.order import Order


@pytest.fixture(scope="session")
def app():
    """Instance Flask pour toute la session de tests."""
    return create_app(TestingConfig)


@pytest.fixture(scope="function")
def client(app):
    """
    Client HTTP de test Flask — utilisé uniquement pour tester /health.
    Le consumer RabbitMQ n'est jamais démarré ici (voir docstring du module).
    """
    return app.test_client()


@pytest.fixture(scope="function", autouse=True)
def clean_db(app):
    """Vide la table orders avant chaque test."""
    with app.app_context():
        _db.session.query(Order).delete()
        _db.session.commit()
    yield


@pytest.fixture
def mock_channel():
    """
    Channel RabbitMQ simulé.

    Dans les tests, on ne veut pas de vraie connexion RabbitMQ.
    MagicMock crée un objet qui accepte n'importe quel appel de méthode
    et enregistre ce qui a été appelé — ce qui nous permet de vérifier
    que basic_ack ou basic_nack ont bien été appelés.
    """
    return MagicMock()


@pytest.fixture
def mock_method():
    """
    Objet 'method' RabbitMQ simulé avec un delivery_tag.
    Le delivery_tag est l'identifiant unique du message,
    utilisé dans basic_ack/basic_nack.
    """
    method = MagicMock()
    method.delivery_tag = 42
    return method
