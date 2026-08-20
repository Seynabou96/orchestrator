"""
Instance SQLAlchemy partagée — même pattern qu'inventory-app.
Découplée de l'app Flask pour éviter les imports circulaires.
"""

from flask_sqlalchemy import SQLAlchemy

db: SQLAlchemy = SQLAlchemy()
