from flask import Flask, request, jsonify, Response
from flask_sqlalchemy import SQLAlchemy
import os
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('INVENTORY_DB_URL')
db = SQLAlchemy(app)

class Movie(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(100), nullable=False)
    description = db.Column(db.Text)
    def __init__(self, **kwargs):
        super(Movie, self).__init__(**kwargs)  # initialisation SQLAlchemy


# ajout pour le healthcheck        
@app.route("/health")
def health():
    return "OK", 200

@app.route('/api/movies', methods=['GET', 'POST', 'DELETE'])
def handle_movies():
    if request.method == 'GET':
        title_filter = request.args.get('title')
        query = Movie.query
        if title_filter:
            query = query.filter(Movie.title.ilike(f'%{title_filter}%'))
        movies = query.all()
        return jsonify([{'id': m.id, 'title': m.title, 'description': m.description} for m in movies])
    elif request.method == 'POST':
        data = request.get_json()  # Utilisation de get_json() au lieu de .json
        # Validation des données
        if not data or 'title' not in data:
            return jsonify({"error": "Missing required title"}), 400
        movie = Movie(title=data['title'], description=data.get('description'))
        db.session.add(movie)
        db.session.commit()
        return jsonify({'id': movie.id, 'title': movie.title, 'description': movie.description}), 200
    elif request.method == 'DELETE':
        Movie.query.delete()
        db.session.commit()
        return Response(status=204)
    else:
        # Cette partie n'est jamais atteinte grâce aux méthodes définies dans le routeur
        return jsonify({"error": "Method not allowed"}), 405

@app.route('/api/movies/<int:id>', methods=['GET', 'PUT', 'DELETE'])
def handle_movie(id):
    movie = Movie.query.get_or_404(id)
    if request.method == 'GET':
        return jsonify({'id': movie.id, 'title': movie.title, 'description': movie.description})
    elif request.method == 'PUT':
        data = request.get_json()
        if not data or 'title' not in data:
            return jsonify({"error": "Missing required title"}), 404
        movie.title = data.get('title', movie.title)
        movie.description = data.get('description', movie.description)
        db.session.commit()
        return jsonify({'id': movie.id, 'title': movie.title, 'description': movie.description})
    elif request.method == 'DELETE':
        db.session.delete(movie)
        db.session.commit()
        return Response(status=204)
    else:
        # Cette partie n'est jamais atteinte grâce aux méthodes définies dans le routeur
        return jsonify({"error": "Method not allowed"}), 405

if __name__ == '__main__':
    with app.app_context():
        db.create_all()
    app.run(host='0.0.0.0', port=8080)