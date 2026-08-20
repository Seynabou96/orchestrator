"""
Gestionnaire de connexion RabbitMQ pour la gateway.

Problème avec une connexion par requête (code de Betzalel) :
    Chaque POST /api/billing ouvre une connexion TCP + AMQP,
    publie, ferme. Sur une charge normale ça tient, mais :
    - Latence ajoutée à chaque requête (~100ms de handshake AMQP)
    - Si RabbitMQ est sous charge, l'ouverture peut échouer
    - Pas de pooling, pas de réutilisation

Solution : connexion persistante avec reconnexion lazy.
    La connexion est créée au premier usage et réutilisée ensuite.
    Si elle est morte (RabbitMQ redémarré, timeout réseau),
    on la recrée à la prochaine requête.

get_channel() est la fonction publique utilisée par la route billing.
"""

import logging

import pika
import pika.exceptions

logger = logging.getLogger(__name__)

_connection = None
_channel = None


def get_channel(config):
    """
    Retourne un canal RabbitMQ valide, en créant ou recréant la connexion
    si nécessaire.

    Args:
        config : objet de configuration Flask (current_app.config),
                 un dict-like — PAS la classe Python Config/TestingConfig.
                 Accès par clé : config["RABBITMQ_HOST"], jamais
                 config.RABBITMQ_HOST (AttributeError garanti sinon —
                 bug réel rencontré ici, jamais détecté par les tests
                 unitaires car get_channel est entièrement mocké dans
                 tests/test_routes.py).

    Returns:
        pika.channel.Channel prêt à publier

    Raises:
        pika.exceptions.AMQPConnectionError : si RabbitMQ est inaccessible
    """
    global _connection, _channel

    # Vérifier si la connexion existante est encore valide
    if _connection is not None and _connection.is_open:
        return _channel

    rabbitmq_host = config["RABBITMQ_HOST"]
    rabbitmq_port = config["RABBITMQ_PORT"]
    rabbitmq_user = config["RABBITMQ_USER"]
    rabbitmq_password = config["RABBITMQ_PASSWORD"]

    logger.info("Ouverture de la connexion RabbitMQ vers %s:%s", rabbitmq_host, rabbitmq_port)

    credentials = pika.PlainCredentials(rabbitmq_user, rabbitmq_password)
    params = pika.ConnectionParameters(
        host=rabbitmq_host,
        port=rabbitmq_port,
        credentials=credentials,
        heartbeat=60,
        # Timeout de connexion : on ne bloque pas une requête HTTP indéfiniment
        connection_attempts=2,
        retry_delay=1,
    )

    _connection = pika.BlockingConnection(params)
    _channel = _connection.channel()

    # Déclarer la queue comme durable — idempotent si elle existe déjà
    _channel.queue_declare(queue="billing_queue", durable=True)

    logger.info("Connexion RabbitMQ établie")
    return _channel
