"""
Modèle Movie — représentation de la table 'movies' en base de données.

SQLAlchemy ORM : au lieu d'écrire du SQL brut, on définit une classe Python
et SQLAlchemy traduit les opérations en requêtes SQL.

Compatibilité SQLAlchemy 2 :
- db.Model comme classe de base (fourni par Flask-SQLAlchemy)
- Pas de declarative_base() qui est déprécié en SQLAlchemy 2
"""

from app.extensions import db


class Movie(db.Model):
    __tablename__ = "movies"

    id: int = db.Column(db.Integer, primary_key=True)
    title: str = db.Column(db.String(200), nullable=False)
    description: str = db.Column(db.Text, nullable=True)

    def to_dict(self) -> dict:
        """
        Sérialise le modèle en dictionnaire pour les réponses JSON.

        Centraliser la sérialisation ici évite de répéter
        {'id': m.id, 'title': m.title, ...} dans chaque route.
        Si on ajoute un champ au modèle, on le met à jour ici
        et toutes les routes bénéficient du changement.
        """
        return {
            "id": self.id,
            "title": self.title,
            "description": self.description,
        }

    def __repr__(self) -> str:
        return f"<Movie id={self.id} title={self.title!r}>"
