import pika
import json
import logging
from sqlalchemy import create_engine, Column, Integer, String
from sqlalchemy.orm import declarative_base, sessionmaker
import os
import time
from dotenv import load_dotenv

# Configuration du logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

# Chargement des variables d'environnement
load_dotenv()

def get_required_env(var_name: str) -> str:
    value = os.getenv(var_name)
    if not value:
        raise RuntimeError(f"La variable d'environnement {var_name} est requise")
    return value

# Configuration de la base de données
Base = declarative_base()
billing_db_url = get_required_env('BILLING_DB_URL')
engine = create_engine(billing_db_url)
Session = sessionmaker(bind=engine)

class Order(Base):
    __tablename__ = 'orders'
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, nullable=False)
    number_of_items = Column(Integer, nullable=False)
    total_amount = Column(Integer, nullable=False)

Base.metadata.create_all(engine)

# Configuration RabbitMQ
rabbitmq_url = get_required_env('RABBITMQ_URL')
rabbitmq_queue = get_required_env('RABBITMQ_QUEUE')

# Connexion à RabbitMQ avec retry
max_retries = 10
retry_delay = 5  # secondes

for attempt in range(max_retries):
    try:
        connection = pika.BlockingConnection(pika.URLParameters(rabbitmq_url))
        channel = connection.channel()
        channel.queue_declare(queue=rabbitmq_queue, durable=True)
        logging.info("Connexion à RabbitMQ réussie.")
        break
    except pika.exceptions.AMQPConnectionError as e:
        logging.error(f"Tentative {attempt + 1}/{max_retries} échouée : {e}")
        time.sleep(retry_delay)
else:
    raise Exception("Impossible de se connecter à RabbitMQ après plusieurs tentatives.")

# Callback pour traitement des messages
def callback(ch, method, properties, body):
    session = Session()
    try:
        data = json.loads(body)
        logging.info(f"Commande reçue : {data}")
        order = Order(
            user_id=data['user_id'],
            number_of_items=data['number_of_items'],
            total_amount=data['total_amount']
        )
        session.add(order)
        session.commit()
        logging.info(f"Commande enregistrée : {order}")
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception as e:
        logging.error(f"Erreur lors du traitement de la commande : {e}")
        session.rollback()
    finally:
        session.close()

# Démarrage de la consommation
channel.basic_consume(queue=rabbitmq_queue, on_message_callback=callback)
logging.info('En attente de messages...')
channel.start_consuming()
