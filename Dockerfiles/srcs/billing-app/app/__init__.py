"""
Factory billing-app.

billing-app combine deux rôles dans le même processus :
1. Un serveur Flask minimal exposant uniquement /health (même contrat
   que inventory-app et api-gateway, pour cohérence avec les outils
   d'orchestration — Docker healthcheck, K3s liveness probe, etc.)
2. Un consumer RabbitMQ qui tourne en parallèle dans un thread séparé
   (voir server.py) — c'est lui qui fait le vrai travail métier.

Flask est aussi utilisé pour bénéficier du contexte applicatif et de la
gestion de session SQLAlchemy, comme avant.

create_app() initialise Flask + SQLAlchemy + les tables + la route /health.
Le consumer est démarré séparément dans server.py, dans un thread dédié.
"""

import logging

from flask import Flask, jsonify

from app.config import Config
from app.extensions import db
from app.models.order import Order  # noqa: F401 — requis pour db.create_all()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)


def create_app(config_class=Config) -> Flask:
    """
    Crée l'application Flask pour billing-app.

    Une seule route HTTP : /health. Pas de logique métier ici —
    le traitement des commandes reste entièrement dans le consumer
    RabbitMQ (app/consumer/billing_consumer.py), inchangé.
    """
    logger = logging.getLogger(__name__)

    config_class.validate()

    app = Flask(__name__)
    app.config.from_object(config_class)

    db.init_app(app)

    with app.app_context():
        db.create_all()

    @app.route("/health")
    def health():
        return jsonify({"status": "ok", "service": "billing-app"}), 200

    logger.info("billing-app initialisée avec %s", config_class.__name__)
    return app
