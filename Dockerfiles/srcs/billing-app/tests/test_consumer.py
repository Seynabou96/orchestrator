"""
Tests unitaires — callback du consumer billing.

On teste la logique du callback directement, sans RabbitMQ réel.
Chaque test simule ce que RabbitMQ ferait :
- appeler callback(channel, method, properties, body)
- vérifier que basic_ack ou basic_nack est appelé correctement
- vérifier l'état de la base de données après traitement

Convention : on importe _get_callback depuis le consumer pour
obtenir le callback configuré avec notre app de test.
"""

import json

import pytest

from app.consumer.billing_consumer import _get_callback
from app.extensions import db
from app.models.order import Order


def make_body(data: dict) -> bytes:
    """Sérialise un dict en bytes JSON — comme RabbitMQ le ferait."""
    return json.dumps(data).encode()


# ---------------------------------------------------------------------------
# Cas nominaux
# ---------------------------------------------------------------------------


def test_valid_message_inserts_order(app, mock_channel, mock_method):
    """Message valide → ordre inséré en DB + basic_ack appelé."""
    callback = _get_callback(app)
    body = make_body({
        "user_id": "3",
        "number_of_items": "5",
        "total_amount": "180"
    })

    callback(mock_channel, mock_method, None, body)

    # Vérifier que basic_ack a été appelé avec le bon delivery_tag
    mock_channel.basic_ack.assert_called_once_with(delivery_tag=42)
    mock_channel.basic_nack.assert_not_called()

    # Vérifier l'insertion en base
    with app.app_context():
        orders = db.session.query(Order).all()
        assert len(orders) == 1
        assert orders[0].user_id == "3"
        assert orders[0].number_of_items == "5"
        assert orders[0].total_amount == "180"


def test_valid_message_with_integer_fields(app, mock_channel, mock_method):
    """Champs entiers (pas des strings) → convertis et insérés correctement."""
    callback = _get_callback(app)
    body = make_body({
        "user_id": 1,
        "number_of_items": 10,
        "total_amount": 250
    })

    callback(mock_channel, mock_method, None, body)

    mock_channel.basic_ack.assert_called_once_with(delivery_tag=42)
    with app.app_context():
        order = db.session.query(Order).first()
        assert order.user_id == "1"
        assert order.total_amount == "250"


def test_multiple_messages_insert_multiple_orders(app, mock_channel, mock_method):
    """Deux messages valides → deux ordres en base."""
    callback = _get_callback(app)

    for i in range(2):
        mock_method.delivery_tag = i
        callback(mock_channel, mock_method, None, make_body({
            "user_id": str(i),
            "number_of_items": "1",
            "total_amount": "10"
        }))

    with app.app_context():
        assert db.session.query(Order).count() == 2


# ---------------------------------------------------------------------------
# Messages invalides — basic_nack attendu
# ---------------------------------------------------------------------------


def test_invalid_json_triggers_nack(app, mock_channel, mock_method):
    """Body non-JSON → basic_nack sans requeue, pas d'insertion."""
    callback = _get_callback(app)

    callback(mock_channel, mock_method, None, b"not valid json {{")

    mock_channel.basic_nack.assert_called_once_with(
        delivery_tag=42, requeue=False
    )
    mock_channel.basic_ack.assert_not_called()

    with app.app_context():
        assert db.session.query(Order).count() == 0


def test_missing_user_id_triggers_nack(app, mock_channel, mock_method):
    """Champ user_id absent → basic_nack sans requeue."""
    callback = _get_callback(app)
    body = make_body({"number_of_items": "5", "total_amount": "180"})

    callback(mock_channel, mock_method, None, body)

    mock_channel.basic_nack.assert_called_once_with(
        delivery_tag=42, requeue=False
    )
    with app.app_context():
        assert db.session.query(Order).count() == 0


def test_missing_number_of_items_triggers_nack(app, mock_channel, mock_method):
    """Champ number_of_items absent → basic_nack sans requeue."""
    callback = _get_callback(app)
    body = make_body({"user_id": "1", "total_amount": "180"})

    callback(mock_channel, mock_method, None, body)

    mock_channel.basic_nack.assert_called_once_with(
        delivery_tag=42, requeue=False
    )


def test_missing_total_amount_triggers_nack(app, mock_channel, mock_method):
    """Champ total_amount absent → basic_nack sans requeue."""
    callback = _get_callback(app)
    body = make_body({"user_id": "1", "number_of_items": "5"})

    callback(mock_channel, mock_method, None, body)

    mock_channel.basic_nack.assert_called_once_with(
        delivery_tag=42, requeue=False
    )


def test_empty_user_id_triggers_nack(app, mock_channel, mock_method):
    """user_id vide (string vide) → basic_nack sans requeue."""
    callback = _get_callback(app)
    body = make_body({
        "user_id": "   ",
        "number_of_items": "5",
        "total_amount": "180"
    })

    callback(mock_channel, mock_method, None, body)

    mock_channel.basic_nack.assert_called_once_with(
        delivery_tag=42, requeue=False
    )


def test_empty_body_triggers_nack(app, mock_channel, mock_method):
    """Body vide → basic_nack sans requeue."""
    callback = _get_callback(app)

    callback(mock_channel, mock_method, None, b"")

    mock_channel.basic_nack.assert_called_once_with(
        delivery_tag=42, requeue=False
    )


def test_empty_json_object_triggers_nack(app, mock_channel, mock_method):
    """JSON valide mais objet vide → basic_nack sans requeue."""
    callback = _get_callback(app)

    callback(mock_channel, mock_method, None, make_body({}))

    mock_channel.basic_nack.assert_called_once_with(
        delivery_tag=42, requeue=False
    )


# ---------------------------------------------------------------------------
# GET /health
# ---------------------------------------------------------------------------


def test_health_check(client):
    """
    billing-app expose /health au même titre que inventory-app
    et api-gateway, indépendamment du consumer RabbitMQ (qui n'est
    pas démarré dans les tests).
    """
    response = client.get("/health")
    assert response.status_code == 200
    data = response.get_json()
    assert data["status"] == "ok"
    assert data["service"] == "billing-app"
