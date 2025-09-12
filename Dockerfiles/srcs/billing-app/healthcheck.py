import pika
import sys
import os
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

rabbitmq_url = os.getenv('RABBITMQ_URL')

if not rabbitmq_url:
    logging.error("RABBITMQ_URL is not set")
    sys.exit(1)

try:
    connection = pika.BlockingConnection(pika.URLParameters(rabbitmq_url))
    connection.close()
    logging.info("Healthcheck réussi : connexion à RabbitMQ OK")
    sys.exit(0)
except Exception as e:
    logging.error(f"Healthcheck failed: {e}")
    sys.exit(1)

