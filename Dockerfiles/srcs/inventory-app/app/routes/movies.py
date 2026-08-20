"""
Blueprint 'movies' — toutes les routes /api/movies/*.

Un Blueprint Flask c'est un groupe de routes avec un préfixe commun,
enregistré dans l'application principale via app.register_blueprint().
Avantages :
- Isolation : ce fichier ne connaît pas Flask app, juste ses routes
- Testabilité : on peut tester le Blueprint sans démarrer l'app entière
- Lisibilité : un fichier = une ressource métier
"""

import logging

from flask import Blueprint, Response, jsonify, request
from sqlalchemy.exc import SQLAlchemyError

from app.extensions import db
from app.models.movie import Movie

logger = logging.getLogger(__name__)

# url_prefix : toutes les routes de ce Blueprint seront préfixées par /api/movies
movies_bp = Blueprint("movies", __name__, url_prefix="/api/movies")


# ---------------------------------------------------------------------------
# Collection : /api/movies
# ---------------------------------------------------------------------------


@movies_bp.route("", methods=["GET"])
def get_movies() -> Response:
    """
    GET /api/movies
    GET /api/movies?title=matrix

    Retourne tous les films, ou filtrés par titre (recherche insensible
    à la casse via ilike — 'i' pour case-insensitive).
    """
    title_filter = request.args.get("title", "").strip()

    try:
        query = db.session.query(Movie)
        if title_filter:
            query = query.filter(Movie.title.ilike(f"%{title_filter}%"))
        movies = query.all()
    except SQLAlchemyError:
        logger.exception("Erreur lors de la récupération des films")
        return jsonify({"error": "Erreur interne du serveur"}), 500

    return jsonify([m.to_dict() for m in movies]), 200


@movies_bp.route("", methods=["POST"])
def create_movie() -> Response:
    """
    POST /api/movies
    Body JSON : {"title": "...", "description": "..."}

    Crée un nouveau film. 'title' est obligatoire.
    Retourne 201 Created avec le film créé.
    """
    data = request.get_json(silent=True)

    # silent=True : renvoie None si le body n'est pas du JSON valide
    # plutôt que de lever une exception
    if not data:
        return jsonify({"error": "Corps JSON requis"}), 400

    title = data.get("title", "").strip()
    if not title:
        return jsonify({"error": "Le champ 'title' est requis"}), 400

    movie = Movie(title=title, description=data.get("description", "").strip() or None)

    try:
        db.session.add(movie)
        db.session.commit()
    except SQLAlchemyError:
        db.session.rollback()
        logger.exception("Erreur lors de la création du film")
        return jsonify({"error": "Erreur interne du serveur"}), 500

    logger.info("Film créé : id=%d title=%r", movie.id, movie.title)
    return jsonify(movie.to_dict()), 201


@movies_bp.route("", methods=["DELETE"])
def delete_all_movies() -> Response:
    """
    DELETE /api/movies

    Supprime tous les films de la base.
    Retourne 204 No Content (succès sans corps de réponse).
    """
    try:
        deleted = db.session.query(Movie).delete()
        db.session.commit()
    except SQLAlchemyError:
        db.session.rollback()
        logger.exception("Erreur lors de la suppression de tous les films")
        return jsonify({"error": "Erreur interne du serveur"}), 500

    logger.info("%d film(s) supprimé(s)", deleted)
    return Response(status=204)


# ---------------------------------------------------------------------------
# Ressource individuelle : /api/movies/<id>
# ---------------------------------------------------------------------------


@movies_bp.route("/<int:movie_id>", methods=["GET"])
def get_movie(movie_id: int) -> Response:
    """
    GET /api/movies/<id>

    Retourne un film par son ID.
    db.session.get() est le remplacement SQLAlchemy 2 de query.get().
    On gère le 404 manuellement pour contrôler le message d'erreur.
    """
    movie = db.session.get(Movie, movie_id)
    if movie is None:
        return jsonify({"error": f"Film {movie_id} introuvable"}), 404

    return jsonify(movie.to_dict()), 200


@movies_bp.route("/<int:movie_id>", methods=["PUT"])
def update_movie(movie_id: int) -> Response:
    """
    PUT /api/movies/<id>
    Body JSON : {"title": "...", "description": "..."}

    Met à jour un film existant.
    - 404 si le film n'existe pas
    - 400 si le body est invalide ou title vide
    - 200 avec le film mis à jour si succès
    """
    movie = db.session.get(Movie, movie_id)
    if movie is None:
        return jsonify({"error": f"Film {movie_id} introuvable"}), 404

    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Corps JSON requis"}), 400

    title = data.get("title", "").strip()
    if not title:
        # 400 Bad Request — pas 404. Le film existe, c'est la requête qui est invalide.
        return jsonify({"error": "Le champ 'title' est requis"}), 400

    movie.title = title
    movie.description = data.get("description", "").strip() or None

    try:
        db.session.commit()
    except SQLAlchemyError:
        db.session.rollback()
        logger.exception("Erreur lors de la mise à jour du film %d", movie_id)
        return jsonify({"error": "Erreur interne du serveur"}), 500

    logger.info("Film mis à jour : id=%d title=%r", movie.id, movie.title)
    return jsonify(movie.to_dict()), 200


@movies_bp.route("/<int:movie_id>", methods=["DELETE"])
def delete_movie(movie_id: int) -> Response:
    """
    DELETE /api/movies/<id>

    Supprime un film par son ID.
    - 404 si le film n'existe pas
    - 204 No Content si suppression réussie
    """
    movie = db.session.get(Movie, movie_id)
    if movie is None:
        return jsonify({"error": f"Film {movie_id} introuvable"}), 404

    try:
        db.session.delete(movie)
        db.session.commit()
    except SQLAlchemyError:
        db.session.rollback()
        logger.exception("Erreur lors de la suppression du film %d", movie_id)
        return jsonify({"error": "Erreur interne du serveur"}), 500

    logger.info("Film supprimé : id=%d", movie_id)
    return Response(status=204)
