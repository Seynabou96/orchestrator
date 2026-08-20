"""
Modèle Order — table 'orders' dans billing_db.

Les trois champs métier (user_id, number_of_items, total_amount)
sont stockés en String conformément au sujet : les messages RabbitMQ
les transmettent sous forme de chaînes JSON et on les conserve tels quels.
La validation de type est faite dans le consumer avant l'insertion.
"""

from app.extensions import db


class Order(db.Model):
    __tablename__ = "orders"

    id: int = db.Column(db.Integer, primary_key=True)
    user_id: str = db.Column(db.String(50), nullable=False)
    number_of_items: str = db.Column(db.String(50), nullable=False)
    total_amount: str = db.Column(db.String(50), nullable=False)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "user_id": self.user_id,
            "number_of_items": self.number_of_items,
            "total_amount": self.total_amount,
        }

    def __repr__(self) -> str:
        return f"<Order id={self.id} user_id={self.user_id!r}>"
