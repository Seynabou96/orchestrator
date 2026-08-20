"""
Tests unitaires — routes api-gateway.

Stratégie de mock :
- requests.request est mocké pour simuler les réponses d'inventory-app
- app.extensions.get_channel est mocké pour simuler RabbitMQ

On teste :
1. Le proxy movies : que la gateway transmet correctement les requêtes
   et retourne les bonnes réponses (status code, body)
2. Le publisher billing : que le message est publié avec les bons paramètres
   et que les cas d'erreur retournent les bons status codes
3. La route /health
4. Les cas d'erreur : service inaccessible, payload invalide
"""

import json
from unittest.mock import MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# /health
# ---------------------------------------------------------------------------

def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    data = response.get_json()
    assert data["status"] == "ok"
    assert data["service"] == "api-gateway"


# ---------------------------------------------------------------------------
# Proxy /api/movies — GET
# ---------------------------------------------------------------------------

def test_get_movies_proxied(client):
    """GET /api/movies → transmis à inventory, réponse retournée telle quelle."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.content = json.dumps([{"id": 1, "title": "Matrix"}]).encode()
    mock_response.headers = {"Content-Type": "application/json"}

    with patch("app.routes.movies.requests.request", return_value=mock_response) as mock_req:
        response = client.get("/api/movies")

    assert response.status_code == 200
    assert response.get_json() == [{"id": 1, "title": "Matrix"}]
    mock_req.assert_called_once()
    call_kwargs = mock_req.call_args
    assert call_kwargs[1]["method"] == "GET" or call_kwargs[0][0] == "GET"


def test_get_movies_with_filter_proxied(client):
    """GET /api/movies?title=matrix → query string transmis à inventory."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.content = b"[]"
    mock_response.headers = {"Content-Type": "application/json"}

    with patch("app.routes.movies.requests.request", return_value=mock_response) as mock_req:
        response = client.get("/api/movies?title=matrix")

    assert response.status_code == 200
    # Vérifier que les params ont été transmis
    call_kwargs = mock_req.call_args[1]
    assert "title" in str(call_kwargs.get("params", ""))


def test_get_movie_by_id_proxied(client):
    """GET /api/movies/1 → transmis à inventory avec l'id."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.content = json.dumps({"id": 1, "title": "Matrix"}).encode()
    mock_response.headers = {"Content-Type": "application/json"}

    with patch("app.routes.movies.requests.request", return_value=mock_response):
        response = client.get("/api/movies/1")

    assert response.status_code == 200


def test_get_movie_not_found_proxied(client):
    """GET /api/movies/999 → inventory retourne 404, gateway retourne 404."""
    mock_response = MagicMock()
    mock_response.status_code = 404
    mock_response.content = json.dumps({"error": "Film 999 introuvable"}).encode()
    mock_response.headers = {"Content-Type": "application/json"}

    with patch("app.routes.movies.requests.request", return_value=mock_response):
        response = client.get("/api/movies/999")

    assert response.status_code == 404


# ---------------------------------------------------------------------------
# Proxy /api/movies — POST, PUT, DELETE
# ---------------------------------------------------------------------------

def test_post_movie_proxied(client):
    """POST /api/movies → transmis à inventory, 201 retourné."""
    mock_response = MagicMock()
    mock_response.status_code = 201
    mock_response.content = json.dumps({"id": 1, "title": "Dune"}).encode()
    mock_response.headers = {"Content-Type": "application/json"}

    with patch("app.routes.movies.requests.request", return_value=mock_response):
        response = client.post(
            "/api/movies",
            data=json.dumps({"title": "Dune"}),
            content_type="application/json",
        )

    assert response.status_code == 201


def test_put_movie_proxied(client):
    """PUT /api/movies/1 → transmis à inventory, 200 retourné."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.content = json.dumps({"id": 1, "title": "Nouveau titre"}).encode()
    mock_response.headers = {"Content-Type": "application/json"}

    with patch("app.routes.movies.requests.request", return_value=mock_response):
        response = client.put(
            "/api/movies/1",
            data=json.dumps({"title": "Nouveau titre"}),
            content_type="application/json",
        )

    assert response.status_code == 200


def test_delete_movie_proxied(client):
    """DELETE /api/movies/1 → transmis à inventory, 204 retourné."""
    mock_response = MagicMock()
    mock_response.status_code = 204
    mock_response.content = b""
    mock_response.headers = {"Content-Type": "application/json"}

    with patch("app.routes.movies.requests.request", return_value=mock_response):
        response = client.delete("/api/movies/1")

    assert response.status_code == 204


def test_delete_all_movies_proxied(client):
    """DELETE /api/movies → transmis à inventory, 204 retourné."""
    mock_response = MagicMock()
    mock_response.status_code = 204
    mock_response.content = b""
    mock_response.headers = {"Content-Type": "application/json"}

    with patch("app.routes.movies.requests.request", return_value=mock_response):
        response = client.delete("/api/movies")

    assert response.status_code == 204


# ---------------------------------------------------------------------------
# Proxy — cas d'erreur réseau
# ---------------------------------------------------------------------------

def test_inventory_unreachable_returns_503(client):
    """Si inventory-app est inaccessible → 503 Service Unavailable."""
    import requests.exceptions

    with patch(
        "app.routes.movies.requests.request",
        side_effect=requests.exceptions.ConnectionError("refused"),
    ):
        response = client.get("/api/movies")

    assert response.status_code == 503
    assert "error" in response.get_json()


def test_inventory_timeout_returns_504(client):
    """Si inventory-app timeout → 504 Gateway Timeout."""
    import requests.exceptions

    with patch(
        "app.routes.movies.requests.request",
        side_effect=requests.exceptions.Timeout("timeout"),
    ):
        response = client.get("/api/movies")

    assert response.status_code == 504


# ---------------------------------------------------------------------------
# POST /api/billing
# ---------------------------------------------------------------------------

def test_post_billing_success(client):
    """Payload valide → publié dans RabbitMQ, 202 Accepted."""
    mock_channel = MagicMock()

    with patch("app.routes.billing.get_channel", return_value=mock_channel):
        response = client.post(
            "/api/billing",
            data=json.dumps({
                "user_id": "3",
                "number_of_items": "5",
                "total_amount": "180",
            }),
            content_type="application/json",
        )

    assert response.status_code == 202
    assert response.get_json()["message"] == "Message posted"
    mock_channel.basic_publish.assert_called_once()


def test_post_billing_verifies_publish_params(client):
    """basic_publish est appelé avec delivery_mode=2 (persistant)."""
    mock_channel = MagicMock()

    with patch("app.routes.billing.get_channel", return_value=mock_channel):
        client.post(
            "/api/billing",
            data=json.dumps({
                "user_id": "1",
                "number_of_items": "2",
                "total_amount": "50",
            }),
            content_type="application/json",
        )

    call_kwargs = mock_channel.basic_publish.call_args[1]
    assert call_kwargs["routing_key"] == "billing_queue"
    assert call_kwargs["properties"].delivery_mode == 2


def test_post_billing_no_body_returns_400(client):
    """Body absent → 400 Bad Request."""
    response = client.post("/api/billing", content_type="application/json")
    assert response.status_code == 400


def test_post_billing_missing_fields_returns_400(client):
    """Champs requis manquants → 400 Bad Request."""
    response = client.post(
        "/api/billing",
        data=json.dumps({"user_id": "1"}),
        content_type="application/json",
    )
    assert response.status_code == 400


def test_post_billing_rabbitmq_down_returns_503(client):
    """Si RabbitMQ est inaccessible → 503 Service Unavailable."""
    import pika.exceptions

    with patch(
        "app.routes.billing.get_channel",
        side_effect=pika.exceptions.AMQPConnectionError("refused"),
    ):
        response = client.post(
            "/api/billing",
            data=json.dumps({
                "user_id": "1",
                "number_of_items": "1",
                "total_amount": "10",
            }),
            content_type="application/json",
        )

    assert response.status_code == 503
    assert "error" in response.get_json()


# ---------------------------------------------------------------------------
# Test d'intégration de get_channel() — n'utilise PAS de mock sur get_channel
# lui-même, contrairement aux tests ci-dessus.
#
# Pourquoi ce test existe : un bug réel a échappé à toute la suite parce que
# get_channel() était systématiquement mocké directement, ce qui masquait
# un AttributeError sur l'accès à current_app.config (dict-like, accès par
# clé) traité comme un objet (accès par attribut) à l'intérieur de
# get_channel(). Ce test exerce le vrai code de extensions.py en ne mockant
# que la couche réseau (pika.BlockingConnection), pour garantir que l'accès
# à current_app.config reste correct même si get_channel() est refactorisé.
# ---------------------------------------------------------------------------

def test_get_channel_reads_config_correctly(app):
    """
    get_channel() doit lire RABBITMQ_HOST/PORT/USER/PASSWORD depuis
    current_app.config (accès par clé), sans jamais lever d'AttributeError.
    Seule la connexion réseau pika est mockée — pas get_channel() lui-même.
    """
    import app.extensions as extensions_module

    # Réinitialise l'état module-level pour ne pas réutiliser une connexion
    # "ouverte" laissée par un test précédent dans la même session pytest.
    extensions_module._connection = None
    extensions_module._channel = None

    mock_connection = MagicMock()
    mock_connection.is_open = True
    mock_channel = MagicMock()
    mock_connection.channel.return_value = mock_channel

    with app.app_context():
        with patch("app.extensions.pika.BlockingConnection", return_value=mock_connection):
            channel = extensions_module.get_channel(app.config)

    assert channel is mock_channel
    mock_channel.queue_declare.assert_called_once_with(queue="billing_queue", durable=True)

    # Nettoyage : éviter qu'un état "connexion ouverte" fuite vers d'autres tests.
    extensions_module._connection = None
    extensions_module._channel = None

