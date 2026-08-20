"""
Application Factory — point de création de l'application Flask.

Pattern "Application Factory" :
    Au lieu de créer `app = Flask(__name__)` au niveau module (global),
    on le crée dans une fonction create_app().

    Pourquoi ?
    1. Les tests appellent create_app(TestingConfig) pour avoir une app
       configurée différemment (SQLite au lieu de PostgreSQL).
    2. On évite les imports circulaires : db est créé dans extensions.py,
       associé à app ici, les routes importent db depuis extensions.py.
    3. Plusieurs instances de l'app peuvent coexister (tests parallèles).

Flux d'initialisation :
    server.py appelle create_app()
    → config validée
    → extensions initialisées (db)
    → tables créées si absentes
    → blueprints enregistrés
    → app retournée
"""

import logging
import logging.config

from flask import Flask, jsonify

from app.config import Config
from app.extensions import db
from app.routes.movies import movies_bp

# ---------------------------------------------------------------------------
# Configuration du logging
# ---------------------------------------------------------------------------
# Format lisible en développement, parseable en production.
# On log l'heure, le niveau, le module source et le message.
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)


def create_app(config_class=Config) -> Flask:
    """
    Crée et configure l'application Flask.

    Args:
        config_class: classe de configuration à utiliser.
                      Config par défaut, TestingConfig dans les tests.

    Returns:
        Instance Flask configurée et prête à recevoir des requêtes.
    """
    logger = logging.getLogger(__name__)

    # Valider la config avant de créer quoi que ce soit
    config_class.validate()

    app = Flask(__name__)
    app.config.from_object(config_class)

    # --- Extensions ---
    # db.init_app() associe l'instance SQLAlchemy à cette app Flask.
    # Sans ça, SQLAlchemy ne sait pas quelle base de données utiliser.
    db.init_app(app)

    # --- Création des tables ---
    # create_all() crée les tables définies dans les modèles si elles
    # n'existent pas encore. Idempotent : sans effet si déjà créées.
    with app.app_context():
        db.create_all()

    # --- Blueprints ---
    # register_blueprint() branche les routes du Blueprint sur l'app.
    # À ce moment, /api/movies/* devient accessible.
    app.register_blueprint(movies_bp)

    # --- Route de santé ---
    # Pas dans un Blueprint car elle appartient à l'app elle-même,
    # pas à une ressource métier. Retourne 200 si l'app répond.
    # Note : ne vérifie pas la connexion DB — c'est voulu à ce stade.
    # K3s et ECS auront des health checks DB séparés (projet suivant).
    @app.route("/health")
    def health():
        return jsonify({"status": "ok", "service": "inventory-app"}), 200

    logger.info("inventory-app démarrée avec %s", config_class.__name__)
    return app
