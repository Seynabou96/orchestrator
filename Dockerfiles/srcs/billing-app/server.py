"""
Point d'entrée de billing-app.

Deux activités tournent en parallèle dans ce processus :
1. Le consumer RabbitMQ (start_consumer) — fait le vrai travail métier,
   bloquant par nature (channel.start_consuming() ne retourne jamais
   en fonctionnement normal). Logique inchangée, voir
   app/consumer/billing_consumer.py.
2. Un serveur Flask minimal exposant uniquement /health — pour que
   billing-app réponde au même contrat que inventory-app et api-gateway
   (utile pour Docker HEALTHCHECK, K3s liveness probe, etc. plus tard).

Pourquoi un thread pour le consumer plutôt que pour Flask ?
Le consumer est la fonction bloquante : si on le lançait dans le thread
principal, app.run() ne serait jamais atteint. On le lance donc dans un
thread daemon en arrière-plan, et le thread principal sert Flask — qui
gère nativement les requêtes HTTP entrantes sans bloquer le programme.
daemon=True garantit que ce thread s'arrête avec le processus principal,
sans empêcher l'arrêt du programme (ex: CTRL+C, kill du conteneur).

Séquence de démarrage :
1. Charger le .env
2. Créer l'app Flask (initialise DB + tables + route /health)
3. Démarrer le consumer RabbitMQ dans un thread séparé
4. Démarrer le serveur Flask dans le thread principal

Note production : en conteneur, le Dockerfile lance gunicorn pour le
serveur HTTP — le thread consumer démarre alors au chargement du module
applicatif (avant que gunicorn ne serve les requêtes), de la même façon.
"""

import os
import threading

from dotenv import load_dotenv

load_dotenv()

from app import create_app  # noqa: E402
from app.consumer.billing_consumer import start_consumer  # noqa: E402

app = create_app()

# Le consumer démarre dans un thread daemon dès l'import du module,
# que l'app soit lancée via `python server.py` ou via gunicorn.
# Sans ça, sous gunicorn, le bloc `if __name__ == "__main__"` ne serait
# jamais exécuté (gunicorn importe `app` directement, il ne lance pas
# ce fichier comme script), et le consumer ne démarrerait jamais.
_consumer_thread = threading.Thread(
    target=start_consumer,
    args=(app,),
    daemon=True,
    name="billing-consumer",
)
_consumer_thread.start()

if __name__ == "__main__":
    port = int(os.getenv("BILLING_APP_PORT", "8080"))
    app.run(host="0.0.0.0", port=port, debug=False)
