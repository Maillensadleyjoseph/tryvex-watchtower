import psycopg2
import psycopg2.extras
import os


class Database:
    def __init__(self):
        self.conn = psycopg2.connect(
            host=os.getenv("DB_HOST", "localhost"),
            port=int(os.getenv("DB_PORT", "6432")),
            dbname=os.getenv("DB_NAME", "watchtower"),
            user=os.getenv("DB_USER", "appuser"),
            password=os.getenv("DB_PASSWORD", ""),
            cursor_factory=psycopg2.extras.RealDictCursor,
            connect_timeout=5,
        )
        self.conn.autocommit = True

    def fetch(self, query, params=None):
        with self.conn.cursor() as cur:
            cur.execute(query, params)
            return cur.fetchall()

    def fetchone(self, query, params=None):
        with self.conn.cursor() as cur:
            cur.execute(query, params)
            return cur.fetchone()

    def execute(self, query, params=None):
        with self.conn.cursor() as cur:
            cur.execute(query, params)


def get_db():
    db = Database()
    try:
        yield db
    finally:
        db.conn.close()
