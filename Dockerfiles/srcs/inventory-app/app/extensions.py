"""
Extensions Flask — instances partagées entre les modules.

Problème sans ce fichier :
    __init__.py crée `app` et `db`
    models/movie.py importe `db` depuis __init__.py
    __init__.py importe Movie depuis models/movie.py
    → Import circulaire, Python refuse de démarrer.

Solution : `db` est créé ici, sans référence à `app`.
Flask-SQLAlchemy associe `db` à `app` plus tard dans create_app()
via db.init_app(app). C'est le pattern "extension découplée".
"""

from flask_sqlalchemy import SQLAlchemy

db: SQLAlchemy = SQLAlchemy()
