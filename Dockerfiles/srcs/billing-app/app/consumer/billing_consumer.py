"""
Consumer RabbitMQ — cœur du service billing.

Responsabilités :
1. Se connecter à RabbitMQ avec retry et backoff exponentiel
2. Déclarer la queue billing_queue (idempotent)
3. Consommer les messages en continu
4. Pour chaque message : valider → insérer en DB → ack
5. Sur message corrompu : nack sans requeue (pas de boucle infinie)
6. Sur perte de connexion : se reconnecter automatiquement

Pourquoi le backoff exponentiel ?
Sur Vagrant, billing-app peut démarrer avant que RabbitMQ soit prêt.
Sans retry, le consumer plante une fois et PM2 le redémarre en boucle
toutes les secondes — ce qui sature les logs et retarde la reconnexion.
Avec backoff : 2s → 4s → 8s → 16s → 32s (plafonné). Le service
se connecte dès que RabbitMQ est prêt, sans flood.

Pourquoi basic_nack avec requeue=False sur payload invalide ?
Un message JSON malformé ou avec des champs manquants ne sera JAMAIS
traitable. Le remettre en queue (requeue=True) crée une boucle infinie
qui sature la queue et bloque les vrais messages. La bonne pratique
production est un Dead Letter Exchange (DLX) — noté comme amélioration
future dans le README, hors scope de ce projet.
"""

import json
import logging
import time

import pika
import pika.exceptions
from flask import Flask
from sqlalchemy.exc import SQLAlchemyError

from app.extensions import db
from app.models.order import Order

logger = logging.getLogger(__name__)

QUEUE_NAME = "billing_queue"
MAX_RETRY_DELAY = 32  # secondes — plafond du backoff exponentiel


def _get_callback(flask_app: Flask):
    """
    Retourne le callback RabbitMQ configuré avec le contexte Flask.

    Pourquoi une factory de callback ?
    Le callback pika s'exécute dans le thread du consumer, pas dans
    un contexte de requête Flask. SQLAlchemy a besoin du contexte
    applicatif Flask (flask_app.app_context()) pour accéder à la DB.
    On capture flask_app dans la closure pour l'utiliser dans le callback.
    """

    def callback(channel, method, properties, body):
        """
        Traite un message RabbitMQ.

        Args:
            channel   : canal AMQP — utilisé pour ack/nack
            method    : métadonnées de livraison (delivery_tag pour ack)
            properties: propriétés du message (non utilisées ici)
            body      : contenu brut du message (bytes)
        """
        # --- Désérialisation ---
        try:
            data = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            # Message non parseable : on le rejette définitivement.
            # requeue=False : ne pas remettre en queue.
            logger.error("Message non JSON reçu, rejeté : %r", body[:200])
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
            return

        # --- Validation des champs requis ---
        required_fields = ["user_id", "number_of_items", "total_amount"]
        missing = [f for f in required_fields if not str(data.get(f, "")).strip()]
        if missing:
            logger.error(
                "Message invalide — champs manquants ou vides : %s",
                missing,
            )
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
            return

        # --- Insertion en base ---
        # Le contexte Flask est requis pour que SQLAlchemy trouve la session DB.
        with flask_app.app_context():
            order = Order(
                user_id=str(data["user_id"]).strip(),
                number_of_items=str(data["number_of_items"]).strip(),
                total_amount=str(data["total_amount"]).strip(),
            )
            try:
                db.session.add(order)
                db.session.commit()
                # Le log doit être DANS le contexte : après commit, SQLAlchemy
                # expire les attributs. Accéder à order.id hors contexte
                # déclenche un DetachedInstanceError.
                order_id = order.id
                order_user = order.user_id
            except SQLAlchemyError:
                db.session.rollback()
                # Erreur DB temporaire (connexion perdue, contrainte) :
                # on remet le message en queue pour réessayer plus tard.
                logger.exception(
                    "Erreur DB lors de l'insertion de l'ordre — message remis en queue"
                )
                channel.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
                return

        logger.info("Ordre inséré : id=%d user_id=%s", order_id, order_user)
        # Acquittement : signale à RabbitMQ que le message est traité.
        # Sans ack, RabbitMQ garde le message "unacked" et le relivrera
        # à la reconnexion du consumer.
        channel.basic_ack(delivery_tag=method.delivery_tag)

    return callback


def start_consumer(flask_app: Flask) -> None:
    """
    Démarre la boucle de consommation RabbitMQ avec retry automatique.

    Cette fonction est bloquante : elle tourne indéfiniment en consommant
    des messages. Elle ne retourne que si le processus est arrêté.

    Le retry avec backoff gère deux cas :
    - RabbitMQ pas encore prêt au démarrage (Vagrant)
    - Perte de connexion en cours de route (redémarrage RabbitMQ, réseau)
    """
    rabbitmq_url = flask_app.config["RABBITMQ_URL"]
    retry_delay = 2  # secondes, doublé à chaque tentative

    while True:
        try:
            logger.info("Connexion à RabbitMQ : %s", _mask_url(rabbitmq_url))
            params = pika.URLParameters(rabbitmq_url)
            # heartbeat=60 : RabbitMQ envoie un ping toutes les 60s pour
            # détecter les connexions mortes. Sans ça, une connexion idle
            # peut être coupée silencieusement par un firewall.
            params.heartbeat = 60
            connection = pika.BlockingConnection(params)
            channel = connection.channel()

            # Déclarer la queue comme durable : survit au redémarrage de RabbitMQ.
            # Si la queue existe déjà avec les mêmes paramètres : no-op.
            # Si elle existe avec des paramètres différents : erreur (voulu).
            channel.queue_declare(queue=QUEUE_NAME, durable=True)

            # prefetch_count=1 : ne pas livrer un 2e message tant que le 1er
            # n'est pas acquitté. Garantit un traitement ordonné et évite
            # de surcharger le consumer si les messages arrivent vite.
            channel.basic_qos(prefetch_count=1)

            channel.basic_consume(
                queue=QUEUE_NAME,
                on_message_callback=_get_callback(flask_app),
            )

            retry_delay = 2  # reset du délai après connexion réussie
            logger.info("Consumer démarré — écoute de '%s'", QUEUE_NAME)
            channel.start_consuming()

        except pika.exceptions.AMQPConnectionError as exc:
            logger.warning(
                "Connexion RabbitMQ échouée (%s). Nouvelle tentative dans %ds",
                exc,
                retry_delay,
            )
            time.sleep(retry_delay)
            retry_delay = min(retry_delay * 2, MAX_RETRY_DELAY)

        except KeyboardInterrupt:
            logger.info("Arrêt du consumer demandé")
            break

        except Exception:
            logger.exception(
                "Erreur inattendue dans le consumer. Reconnexion dans %ds",
                retry_delay,
            )
            time.sleep(retry_delay)
            retry_delay = min(retry_delay * 2, MAX_RETRY_DELAY)


def _mask_url(url: str) -> str:
    """
    Masque le mot de passe dans l'URL pour les logs.

    amqp://user:secret@host:5672/ → amqp://user:***@host:5672/

    On ne logue JAMAIS de credentials en clair, même en développement.
    C'est une règle DevSecOps de base : les logs sont souvent accessibles
    à plus de personnes que le code source.
    """
    try:
        import urllib.parse
        parsed = urllib.parse.urlparse(url)
        if parsed.password:
            masked = parsed._replace(
                netloc=f"{parsed.username}:***@{parsed.hostname}:{parsed.port}"
            )
            return urllib.parse.urlunparse(masked)
    except Exception:
        pass
    return url
