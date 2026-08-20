"""
Blueprint 'movies' — proxy transparent vers inventory-app.

La gateway ne connaît pas la logique métier des films.
Elle transmet la requête telle quelle et retourne la réponse telle quelle.

"Proxy transparent" signifie :
- Même méthode HTTP (GET, POST, PUT, DELETE)
- Même body
- Même query string (?title=matrix)
- Même status code retourné
- Headers Content-Type préservés

Pourquoi ne pas juste faire un redirect ?
Un redirect (301/302) renvoie le client directement vers inventory-app,
ce qui exposerait l'adresse IP interne du réseau Vagrant.
Le proxy garde l'architecture opaque : le client ne voit que la gateway.
"""

import logging

import requests
import requests.exceptions
from flask import Blueprint, Response, current_app, jsonify, request

logger = logging.getLogger(__name__)

movies_bp = Blueprint("movies", __name__, url_prefix="/api/movies")

# Timeout pour les appels vers inventory-app.
# 10s est généreux pour un réseau local Vagrant — à réduire en production.
INVENTORY_TIMEOUT = 10


def _inventory_url(path: str = "") -> str:
    """Construit l'URL complète vers inventory-app."""
    base = current_app.config["INVENTORY_API_URL"].rstrip("/")
    return f"{base}/api/movies{path}"


def _proxy(method: str, path: str = "") -> Response:
    """
    Effectue la requête vers inventory-app et retourne la réponse.

    Préserve : méthode, body, query params, status code.
    Ne préserve pas les headers hop-by-hop (Transfer-Encoding, Connection)
    qui sont spécifiques à la connexion HTTP et ne doivent pas être
    retransmis dans un proxy.
    """
    url = _inventory_url(path)
    try:
        resp = requests.request(
            method=method,
            url=url,
            params=request.args,
            json=request.get_json(silent=True),
            timeout=INVENTORY_TIMEOUT,
        )
    except requests.exceptions.ConnectionError:
        logger.error("Inventory-app inaccessible : %s", url)
        return jsonify({"error": "Service inventaire inaccessible"}), 503
    except requests.exceptions.Timeout:
        logger.error("Timeout vers inventory-app : %s", url)
        return jsonify({"error": "Service inventaire timeout"}), 504

    # Retransmettre la réponse telle quelle
    return Response(
        response=resp.content,
        status=resp.status_code,
        content_type=resp.headers.get("Content-Type", "application/json"),
    )


# ---------------------------------------------------------------------------
# Routes — délèguent toutes à _proxy()
# ---------------------------------------------------------------------------

@movies_bp.route("", methods=["GET"])
def get_movies():
    return _proxy("GET")


@movies_bp.route("", methods=["POST"])
def create_movie():
    return _proxy("POST")


@movies_bp.route("", methods=["DELETE"])
def delete_all_movies():
    return _proxy("DELETE")


@movies_bp.route("/<path:subpath>", methods=["GET"])
def get_movie(subpath):
    return _proxy("GET", f"/{subpath}")


@movies_bp.route("/<path:subpath>", methods=["PUT"])
def update_movie(subpath):
    return _proxy("PUT", f"/{subpath}")


@movies_bp.route("/<path:subpath>", methods=["DELETE"])
def delete_movie(subpath):
    return _proxy("DELETE", f"/{subpath}")
