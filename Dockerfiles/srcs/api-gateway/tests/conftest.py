"""
Fixtures pour les tests api-gateway.

Deux choses à mocker :
1. requests.request — pour ne pas faire de vrais appels HTTP vers inventory-app
2. app.extensions.get_channel — pour ne pas ouvrir de vraie connexion RabbitMQ

On utilise unittest.mock.patch comme context manager dans chaque test
pour un contrôle précis de ce qui est mocké et comment.
"""

import pytest
from app import create_app
from app.config import TestingConfig


@pytest.fixture(scope="session")
def app():
    return create_app(TestingConfig)


@pytest.fixture(scope="function")
def client(app):
    return app.test_client()
