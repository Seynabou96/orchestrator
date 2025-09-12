from flask import Flask, request, jsonify, Response, make_response
import requests
import pika
import json
import os
from dotenv import load_dotenv
from typing import Dict, Any
import logging
from pathlib import Path

# Crée le dossier logs si inexistant
Path("/var/lib/api_gateway_app/logs").mkdir(parents=True, exist_ok=True)

# Configure le logging
logging.basicConfig(
    filename="/var/lib/api_gateway_app/logs/app.log",
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Exemple d'utilisation
logger.info("Démarrage de l'API Gateway")
load_dotenv()

def get_required_env(var_name: str) -> str:
    value = os.getenv(var_name)
    if not value:
        raise RuntimeError(f"La variable d'environnement {var_name} est requise")
    return value

app = Flask(__name__)
INVENTORY_API_URL = get_required_env('INVENTORY_API_URL')
rabbitmq_queue = get_required_env('RABBITMQ_QUEUE')
exposed_port = get_required_env('EXPOSED_PORT')
RABBITMQ_CREDS = pika.PlainCredentials(
    get_required_env('RABBITMQ_USER'),
    get_required_env('RABBITMQ_PASSWORD')
)
RABBITMQ_PARAMS = pika.ConnectionParameters(
    host=get_required_env('RABBITMQ_HOST'),
    credentials=RABBITMQ_CREDS
)

@app.route('/api/movies', methods=['GET', 'POST', 'DELETE'])
@app.route('/api/movies/<path:subpath>', methods=['GET', 'PUT', 'DELETE'])
def proxy_inventory(subpath: str = '') -> Response:
    url = f"{INVENTORY_API_URL}/api/movies/{subpath}".rstrip('/')
    
    # Conversion explicite des paramètres
    params = request.args.to_dict()
    
    resp = requests.request(
        method=request.method,
        url=url,
        headers={key: value for key, value in request.headers if key != 'Host'},
        data=request.get_data(),
        params=params  # Conversion en dict standard
    )
    
    # Construction d'une réponse Flask conforme
    return Response(
        response=resp.content,
        status=resp.status_code,
        headers=dict(resp.headers.items())  # Conversion explicite en dict
    )

@app.route('/api/billing', methods=['POST'])
def handle_billing() -> Response:
    connection = pika.BlockingConnection(RABBITMQ_PARAMS)
    channel = connection.channel()
    channel.queue_declare(queue=rabbitmq_queue, durable=True)
    
    # Validation du payload
    payload = request.get_json()
    if not payload:
        return make_response(jsonify({"error": "Missing JSON payload"}), 400)
    
    channel.basic_publish(
        exchange='',
        routing_key=rabbitmq_queue,
        body=json.dumps(payload),
        properties=pika.BasicProperties(delivery_mode=2)
    )
    
    connection.close()
    return jsonify({"message": "Message posted"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=exposed_port)