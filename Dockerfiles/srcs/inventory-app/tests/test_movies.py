"""
Tests unitaires — routes /api/movies.

Chaque test est indépendant : la fixture clean_db (dans conftest.py)
vide la table movies avant chaque fonction de test.

Convention de nommage : test_<méthode HTTP>_<ressource>_<scénario>
    test_get_movies_empty       → GET /api/movies quand la base est vide
    test_post_movie_success     → POST /api/movies avec un payload valide
    test_post_movie_no_title    → POST /api/movies sans le champ title

Pourquoi tester les cas d'erreur autant que les cas nominaux ?
Un DevSecOps junior doit penser aux entrées malformées, manquantes
ou malveillantes. Tester 400, 404, 204 c'est tester la robustesse.
"""

import json


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def create_movie(client, title="Test Movie", description="Une description"):
    """Raccourci pour créer un film dans les tests."""
    return client.post(
        "/api/movies",
        data=json.dumps({"title": title, "description": description}),
        content_type="application/json",
    )


# ---------------------------------------------------------------------------
# GET /api/movies
# ---------------------------------------------------------------------------


def test_get_movies_empty(client):
    """Base vide → liste vide, status 200."""
    response = client.get("/api/movies")
    assert response.status_code == 200
    assert response.get_json() == []


def test_get_movies_returns_all(client):
    """Deux films créés → les deux retournés."""
    create_movie(client, title="Matrix")
    create_movie(client, title="Inception")

    response = client.get("/api/movies")
    assert response.status_code == 200
    data = response.get_json()
    assert len(data) == 2
    titles = [m["title"] for m in data]
    assert "Matrix" in titles
    assert "Inception" in titles


def test_get_movies_filter_by_title(client):
    """Filtre ?title= retourne uniquement les films correspondants."""
    create_movie(client, title="The Matrix")
    create_movie(client, title="Matrix Reloaded")
    create_movie(client, title="Inception")

    response = client.get("/api/movies?title=matrix")
    assert response.status_code == 200
    data = response.get_json()
    assert len(data) == 2
    assert all("matrix" in m["title"].lower() for m in data)


def test_get_movies_filter_no_match(client):
    """Filtre sans correspondance → liste vide, status 200."""
    create_movie(client, title="Matrix")
    response = client.get("/api/movies?title=inexistant")
    assert response.status_code == 200
    assert response.get_json() == []


# ---------------------------------------------------------------------------
# POST /api/movies
# ---------------------------------------------------------------------------


def test_post_movie_success(client):
    """Création valide → 201, film retourné avec id."""
    response = create_movie(client, title="Dune", description="Un classique de la SF")
    assert response.status_code == 201
    data = response.get_json()
    assert data["title"] == "Dune"
    assert data["description"] == "Un classique de la SF"
    assert "id" in data
    assert isinstance(data["id"], int)


def test_post_movie_without_description(client):
    """'description' est optionnel → 201, description None."""
    response = client.post(
        "/api/movies",
        data=json.dumps({"title": "Sans description"}),
        content_type="application/json",
    )
    assert response.status_code == 201
    data = response.get_json()
    assert data["title"] == "Sans description"
    assert data["description"] is None


def test_post_movie_missing_title(client):
    """'title' absent → 400 Bad Request."""
    response = client.post(
        "/api/movies",
        data=json.dumps({"description": "Pas de titre"}),
        content_type="application/json",
    )
    assert response.status_code == 400
    assert "error" in response.get_json()


def test_post_movie_empty_title(client):
    """'title' vide → 400 Bad Request."""
    response = client.post(
        "/api/movies",
        data=json.dumps({"title": "   "}),
        content_type="application/json",
    )
    assert response.status_code == 400


def test_post_movie_no_body(client):
    """Corps absent → 400 Bad Request."""
    response = client.post("/api/movies", content_type="application/json")
    assert response.status_code == 400


def test_post_movie_invalid_json(client):
    """JSON malformé → 400 Bad Request."""
    response = client.post(
        "/api/movies",
        data="not json",
        content_type="application/json",
    )
    assert response.status_code == 400


# ---------------------------------------------------------------------------
# GET /api/movies/<id>
# ---------------------------------------------------------------------------


def test_get_movie_by_id(client):
    """Film existant → 200, données correctes."""
    created = create_movie(client, title="Interstellar")
    movie_id = created.get_json()["id"]

    response = client.get(f"/api/movies/{movie_id}")
    assert response.status_code == 200
    assert response.get_json()["title"] == "Interstellar"


def test_get_movie_not_found(client):
    """ID inexistant → 404 Not Found."""
    response = client.get("/api/movies/9999")
    assert response.status_code == 404
    assert "error" in response.get_json()


# ---------------------------------------------------------------------------
# PUT /api/movies/<id>
# ---------------------------------------------------------------------------


def test_put_movie_success(client):
    """Mise à jour valide → 200, nouvelles données."""
    movie_id = create_movie(client, title="Ancien titre").get_json()["id"]

    response = client.put(
        f"/api/movies/{movie_id}",
        data=json.dumps({"title": "Nouveau titre", "description": "Nouvelle desc"}),
        content_type="application/json",
    )
    assert response.status_code == 200
    data = response.get_json()
    assert data["title"] == "Nouveau titre"
    assert data["description"] == "Nouvelle desc"


def test_put_movie_not_found(client):
    """ID inexistant → 404 Not Found."""
    response = client.put(
        "/api/movies/9999",
        data=json.dumps({"title": "Titre"}),
        content_type="application/json",
    )
    assert response.status_code == 404


def test_put_movie_missing_title(client):
    """'title' absent → 400 Bad Request (pas 404)."""
    movie_id = create_movie(client, title="Film").get_json()["id"]

    response = client.put(
        f"/api/movies/{movie_id}",
        data=json.dumps({"description": "Nouvelle desc"}),
        content_type="application/json",
    )
    # Correction du bug de Betzalel : c'est 400, pas 404
    assert response.status_code == 400


def test_put_movie_no_body(client):
    """Corps absent → 400 Bad Request."""
    movie_id = create_movie(client, title="Film").get_json()["id"]
    response = client.put(f"/api/movies/{movie_id}", content_type="application/json")
    assert response.status_code == 400


# ---------------------------------------------------------------------------
# DELETE /api/movies/<id>
# ---------------------------------------------------------------------------


def test_delete_movie_success(client):
    """Suppression d'un film existant → 204 No Content."""
    movie_id = create_movie(client, title="À supprimer").get_json()["id"]

    response = client.delete(f"/api/movies/{movie_id}")
    assert response.status_code == 204

    # Vérifier que le film n'existe plus
    get_response = client.get(f"/api/movies/{movie_id}")
    assert get_response.status_code == 404


def test_delete_movie_not_found(client):
    """ID inexistant → 404 Not Found."""
    response = client.delete("/api/movies/9999")
    assert response.status_code == 404


# ---------------------------------------------------------------------------
# DELETE /api/movies
# ---------------------------------------------------------------------------


def test_delete_all_movies(client):
    """Suppression de tous les films → 204, base vide."""
    create_movie(client, title="Film 1")
    create_movie(client, title="Film 2")

    response = client.delete("/api/movies")
    assert response.status_code == 204

    get_response = client.get("/api/movies")
    assert get_response.get_json() == []


def test_delete_all_movies_empty_db(client):
    """Suppression quand la base est déjà vide → 204 (idempotent)."""
    response = client.delete("/api/movies")
    assert response.status_code == 204


# ---------------------------------------------------------------------------
# GET /health
# ---------------------------------------------------------------------------


def test_health_check(client):
    """Health check → 200, status ok."""
    response = client.get("/health")
    assert response.status_code == 200
    data = response.get_json()
    assert data["status"] == "ok"
    assert data["service"] == "inventory-app"
