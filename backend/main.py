import os
import httpx
import smtplib
from email.mime.text import MIMEText
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Depends, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from apscheduler.schedulers.background import BackgroundScheduler

from database import Database, get_db

app = FastAPI(title="Watchtower API", version="1.0.0")
INSTANCE = os.getenv("INSTANCE_NAME", "backend-1")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://app.tryvex.tech", "http://localhost:3000"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


# ─── MODELOS ──────────────────────────────────────────────────

class MonitorCreate(BaseModel):
    nombre: str
    url: str
    intervalo_seg: int = 300
    status_ok: int = 200
    activo: bool = True


# ─── CHEQUEO + ALERTAS ────────────────────────────────────────

def send_alert(nombre: str, url: str, error: str):
    smtp_host = os.getenv("SMTP_HOST", "smtp.zoho.com")
    smtp_port = int(os.getenv("SMTP_PORT", "587"))
    smtp_user = os.getenv("SMTP_USER", "")
    smtp_pass = os.getenv("SMTP_PASSWORD", "")
    alert_to  = os.getenv("ALERT_TO", "")
    if not smtp_user or not alert_to:
        return
    msg = MIMEText(f"Monitor: {nombre}\nURL: {url}\nError: {error}\nInstancia: {INSTANCE}")
    msg["Subject"] = f"[Watchtower] CAÍDA detectada: {nombre}"
    msg["From"] = smtp_user
    msg["To"] = alert_to
    try:
        with smtplib.SMTP(smtp_host, smtp_port, timeout=10) as s:
            s.starttls()
            s.login(smtp_user, smtp_pass)
            s.send_message(msg)
    except Exception:
        pass


def run_checks():
    db = Database()
    try:
        monitors = db.fetch("SELECT * FROM monitor WHERE activo = true")
        for m in monitors:
            start = datetime.now(timezone.utc)
            arriba = False
            status_code = None
            latencia_ms = None
            try:
                r = httpx.get(m["url"], timeout=10, follow_redirects=True)
                latencia_ms = int((datetime.now(timezone.utc) - start).total_seconds() * 1000)
                status_code = r.status_code
                arriba = (status_code == m["status_ok"])
            except Exception as e:
                latencia_ms = int((datetime.now(timezone.utc) - start).total_seconds() * 1000)

            db.execute("""
                INSERT INTO check_result (monitor_id, status_code, latencia_ms, arriba)
                VALUES (%s, %s, %s, %s)
            """, (m["id"], status_code, latencia_ms, arriba))

            if not arriba:
                open_inc = db.fetchone("""
                    SELECT id FROM incidente
                    WHERE monitor_id = %s AND fin IS NULL
                """, (m["id"],))
                if not open_inc:
                    db.execute("""
                        INSERT INTO incidente (monitor_id) VALUES (%s)
                    """, (m["id"],))
                    send_alert(m["nombre"], m["url"], f"status={status_code}")
            else:
                db.execute("""
                    UPDATE incidente SET fin = now()
                    WHERE monitor_id = %s AND fin IS NULL
                """, (m["id"],))
    finally:
        db.conn.close()


# ─── SCHEDULER ────────────────────────────────────────────────

scheduler = BackgroundScheduler()
scheduler.add_job(run_checks, "interval", minutes=5, id="checks")
scheduler.start()


# ─── ENDPOINTS ────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "instance": INSTANCE}


@app.get("/status")
def status(db: Database = Depends(get_db)):
    monitors = db.fetch("SELECT id, nombre, url, activo FROM monitor WHERE activo = true")
    result = []
    for m in monitors:
        last = db.fetchone("""
            SELECT arriba, latencia_ms, checked_at FROM check_result
            WHERE monitor_id = %s ORDER BY checked_at DESC LIMIT 1
        """, (m["id"],))
        result.append({
            "id": m["id"],
            "nombre": m["nombre"],
            "url": m["url"],
            "arriba": last["arriba"] if last else None,
            "latencia_ms": last["latencia_ms"] if last else None,
            "ultimo_chequeo": last["checked_at"].isoformat() if last else None,
        })
    return {"instance": INSTANCE, "monitores": result}


@app.get("/monitors")
def list_monitors(db: Database = Depends(get_db)):
    rows = db.fetch("SELECT * FROM monitor ORDER BY id")
    return [dict(r) for r in rows]


@app.post("/monitors", status_code=201)
def create_monitor(data: MonitorCreate, db: Database = Depends(get_db)):
    row = db.fetchone("""
        INSERT INTO monitor (nombre, url, intervalo_seg, status_ok, activo)
        VALUES (%s, %s, %s, %s, %s) RETURNING *
    """, (data.nombre, data.url, data.intervalo_seg, data.status_ok, data.activo))
    return dict(row)


@app.get("/monitors/{id}/history")
def monitor_history(id: int, limit: int = 50, db: Database = Depends(get_db)):
    monitor = db.fetchone("SELECT * FROM monitor WHERE id = %s", (id,))
    if not monitor:
        raise HTTPException(status_code=404, detail="Monitor no encontrado")
    history = db.fetch("""
        SELECT status_code, latencia_ms, arriba, checked_at
        FROM check_result WHERE monitor_id = %s
        ORDER BY checked_at DESC LIMIT %s
    """, (id, limit))
    return {"monitor": dict(monitor), "history": [dict(r) for r in history]}


@app.on_event("shutdown")
def shutdown():
    scheduler.shutdown()
