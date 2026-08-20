"""
Point d'entrée de l'api-gateway.

Le port d'écoute vient de GATEWAY_APP_PORT (.env / docker-compose),
jamais codé en dur. Le sujet Play with Containers impose le port 3000
pour api-gateway-app — cette valeur doit être définie dans le .env,
pas supposée dans le code.

Note production : en conteneur, le Dockerfile lance gunicorn directement :
    gunicorn --bind 0.0.0.0:${GATEWAY_APP_PORT} --workers 4 "app:create_app()"
"""

import os

from dotenv import load_dotenv

load_dotenv()

from app import create_app  # noqa: E402

app = create_app()

if __name__ == "__main__":
    port = int(os.getenv("GATEWAY_APP_PORT", "3000"))
    app.run(host="0.0.0.0", port=port, debug=False)
