"""
Blueprint 'billing' — publication dans RabbitMQ.

La gateway reçoit un POST /api/billing avec un body JSON,
le sérialise et le publie dans billing_queue.

Points importants :
- delivery_mode=2 : message persistant — survit à un redémarrage RabbitMQ
- La gateway retourne 202 Accepted (pas 200) : le message est accepté
  pour traitement asynchrone mais n'est pas encore traité par billing-app.
  C'est le status code sémantiquement correct pour les opérations async.
- Si RabbitMQ est inaccessible, on retourne 503 avec un message clair.
  La gateway ne ment pas au client en retournant 200 si le message
  n'a pas pu être publié.
"""

import json
import logging

import pika
import pika.exceptions
from flask import Blueprint, current_app, jsonify, request

from app.extensions import get_channel

logger = logging.getLogger(__name__)

billing_bp = Blueprint("billing", __name__, url_prefix="/api/billing")

QUEUE_NAME = "billing_queue"


@billing_bp.route("", methods=["POST"])
def post_billing() -> tuple:
    """
    POST /api/billing
    Body JSON : {"user_id": "...", "number_of_items": "...", "total_amount": "..."}

    Publie le message dans billing_queue et retourne 202 Accepted.
    """
    data = request.get_json(silent=True)

    if not data:
        return jsonify({"error": "Corps JSON requis"}), 400

    # Validation minimale : vérifier que les champs requis sont présents
    required = ["user_id", "number_of_items", "total_amount"]
    missing = [f for f in required if not str(data.get(f, "")).strip()]
    if missing:
        return jsonify({"error": f"Champs requis manquants : {missing}"}), 400

    message = json.dumps(data)

    try:
        channel = get_channel(current_app.config)
        channel.basic_publish(
            exchange="",
            routing_key=QUEUE_NAME,
            body=message,
            properties=pika.BasicProperties(
                delivery_mode=2,  # message persistant
                content_type="application/json",
            ),
        )
    except pika.exceptions.AMQPConnectionError:
        logger.error("Impossible de publier dans RabbitMQ — connexion échouée")
        return jsonify({"error": "Service de messagerie inaccessible"}), 503
    except Exception:
        logger.exception("Erreur inattendue lors de la publication RabbitMQ")
        return jsonify({"error": "Erreur interne du serveur"}), 500

    logger.info("Message publié dans '%s' pour user_id=%s", QUEUE_NAME, data.get("user_id"))
    return jsonify({"message": "Message posted"}), 202
