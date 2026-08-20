"""
Factory api-gateway.

La gateway est le seul point d'entrée exposé à l'extérieur.
Elle ne touche jamais à la base de données directement —
pas de SQLAlchemy, pas de modèles.

Blueprints enregistrés :
- movies_bp : proxy vers inventory-app (/api/movies/*)
- billing_bp : publisher RabbitMQ (/api/billing)
"""

import logging
import os

from flask import Flask, jsonify

from app.config import Config
from app.routes.billing import billing_bp
from app.routes.movies import movies_bp

# Deux handlers : stdout (capturé par `docker logs`, usage courant en
# développement) ET fichier (dans /app/logs, monté sur le volume
# api-gateway-app — exigence explicite du sujet : "api-gateway-app
# volume contains your API gateway logs"). Les deux coexistent, aucun
# ne remplace l'autre.
_LOG_DIR = "/app/logs"
os.makedirs(_LOG_DIR, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(os.path.join(_LOG_DIR, "api-gateway.log")),
    ],
)


def create_app(config_class=Config) -> Flask:
    logger = logging.getLogger(__name__)

    config_class.validate()

    app = Flask(__name__)
    app.config.from_object(config_class)

    app.register_blueprint(movies_bp)
    app.register_blueprint(billing_bp)

    @app.route("/health")
    def health():
        return jsonify({"status": "ok", "service": "api-gateway"}), 200

    logger.info("api-gateway démarrée avec %s", config_class.__name__)
    return app
