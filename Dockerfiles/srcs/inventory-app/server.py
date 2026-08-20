"""
Point d'entrée de l'application.

Ce fichier est volontairement minimal : son seul rôle est de créer
l'application via la factory et de la démarrer.

Toute la logique de configuration et d'initialisation est dans app/.

Le port d'écoute vient de INVENTORY_APP_PORT (même variable que celle
utilisée côté api-gateway pour joindre ce service — voir
api-gateway/app/config.py pour la convention de nommage complète),
jamais codé en dur. Le sujet Play with Containers exige le port 8080
pour inventory-app, mais ce choix doit rester piloté par le .env /
docker-compose, pas figé dans le code source.

Note production : en conteneur, ce fichier n'est plus le point d'entrée.
Le Dockerfile lance gunicorn directement :
    gunicorn --bind 0.0.0.0:${INVENTORY_APP_PORT} --workers 4 "app:create_app()"
Ce server.py reste utile pour le développement local hors conteneur.
"""

import os

from dotenv import load_dotenv

load_dotenv()

from app import create_app  # noqa: E402

app = create_app()

if __name__ == "__main__":
    port = int(os.getenv("INVENTORY_APP_PORT", "8080"))
    app.run(host="0.0.0.0", port=port, debug=False)
