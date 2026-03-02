"""
AgroMercados — Proxy Server Local
==================================
Resuelve CORS para Alpha Vantage y Open-Meteo.
Cachea respuestas para no agotar el límite de 25 calls/día de Alpha Vantage.

Uso:
  python server.py YOUR_ALPHA_VANTAGE_KEY

Obtén tu clave gratis en: https://www.alphavantage.co/support/#api-key
"""

import sys
import json
import time
import os
import requests
from datetime import datetime, timedelta
from flask import Flask, jsonify, request, send_from_directory
from functools import wraps

# ── Configuración ──────────────────────────────────────────────────────────────

API_KEY = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("AV_KEY", "demo")
CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache")
os.makedirs(CACHE_DIR, exist_ok=True)

app = Flask(__name__, static_folder="static")

# ── Símbolos de futuros en Alpha Vantage ──────────────────────────────────────
# Futuros agrícolas más líquidos en CME/ICE:
SYMBOLS = {
    "cafe":   {"sym": "KC",  "name": "Café Arábica",  "unit": "USD/libra",  "icon": "☕", "exchange": "ICE"},
    "maiz":   {"sym": "ZC",  "name": "Maíz",          "unit": "USc/bushel", "icon": "🌽", "exchange": "CBOT"},
    "arroz":  {"sym": "ZR",  "name": "Arroz",         "unit": "USD/cwt",    "icon": "🌾", "exchange": "CBOT"},
    "azucar": {"sym": "SB",  "name": "Azúcar #11",    "unit": "USD/libra",  "icon": "🎋", "exchange": "ICE"},
    "banano": {"sym": "ZS",  "name": "Soya (ref.)",   "unit": "USc/bushel", "icon": "🍌", "exchange": "CBOT"},
}

# Insumos agrícolas (fertilizantes vía futuros/ETF referencia)
INPUT_SYMBOLS = {
    "urea":     {"sym": "CF",   "name": "CF Industries (urea ref.)",  "unit": "USD"},
    "potasio":  {"sym": "MOS",  "name": "Mosaic Co. (potasio ref.)",  "unit": "USD"},
    "petroleo": {"sym": "CL",   "name": "Petróleo WTI (diesel ref.)", "unit": "USD/barril"},
}

# Ubicaciones clima Open-Meteo
WEATHER_LOCS = [
    {"region": "Guatemala",  "lat": 14.64, "lon": -90.51, "country": "ca"},
    {"region": "Costa Rica", "lat":  9.93, "lon": -84.09, "country": "ca"},
    {"region": "Honduras",   "lat": 14.09, "lon": -87.21, "country": "ca"},
    {"region": "Colombia",   "lat":  4.71, "lon": -74.07, "country": "co"},
    {"region": "Venezuela",  "lat": 10.48, "lon": -66.88, "country": "ve"},
    {"region": "Ecuador",    "lat": -0.23, "lon": -78.52, "country": "ec"},
]

# ── Cache en disco ─────────────────────────────────────────────────────────────

def cache_path(key):
    safe = key.replace("/", "_").replace("?", "_").replace("&", "_")
    return os.path.join(CACHE_DIR, f"{safe}.json")

def load_cache(key, max_age_seconds=3600):
    p = cache_path(key)
    if not os.path.exists(p):
        return None
    age = time.time() - os.path.getmtime(p)
    if age > max_age_seconds:
        return None
    with open(p) as f:
        return json.load(f)

def save_cache(key, data):
    with open(cache_path(key), "w") as f:
        json.dump(data, f)

# ── CORS helper ────────────────────────────────────────────────────────────────

def cors(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        resp = f(*args, **kwargs)
        if hasattr(resp, "headers"):
            resp.headers["Access-Control-Allow-Origin"] = "*"
        return resp
    return decorated

@app.after_request
def add_cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return resp

# ── Rutas estáticas ────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return send_from_directory("static", "index.html")

@app.route("/static/<path:path>")
def static_files(path):
    return send_from_directory("static", path)

# ── Alpha Vantage: datos diarios de commodities ────────────────────────────────

@app.route("/api/commodity/<cid>")
def commodity(cid):
    if cid not in SYMBOLS:
        return jsonify({"error": "unknown commodity"}), 404

    sym = SYMBOLS[cid]["sym"]
    cache_key = f"av_daily_{sym}"
    # Commodities: cache 4 horas (precios no cambian tan rápido durante el día)
    cached = load_cache(cache_key, max_age_seconds=4 * 3600)
    if cached:
        return jsonify(cached)

    # Alpha Vantage: TIME_SERIES_DAILY para equities/futuros
    # Para commodities físicos usamos COMMODITY endpoint
    # AV tiene endpoint específico: WTI, BRENT, NATURAL_GAS, COPPER, ALUMINUM,
    # WHEAT, CORN, COTTON, SUGAR, COFFEE (¡directo!)
    COMMODITY_ENDPOINTS = {
        "KC": "COFFEE",
        "ZC": "CORN",
        "ZR": None,          # arroz: usamos TIME_SERIES_DAILY con ZR
        "SB": "SUGAR",
        "ZS": None,          # soya: TIME_SERIES_DAILY
    }

    av_function = COMMODITY_ENDPOINTS.get(sym)
    meta = SYMBOLS[cid]

    if av_function:
        # Endpoint de commodities físicos AV — devuelve daily gratis
        url = (
            f"https://www.alphavantage.co/query"
            f"?function={av_function}&interval=daily&datatype=json&apikey={API_KEY}"
        )
        try:
            r = requests.get(url, timeout=15)
            r.raise_for_status()
            raw = r.json()
            if "data" not in raw:
                raise ValueError(f"AV error: {raw.get('Note', raw.get('Information', raw))}")
            series = [
                {"date": d["date"], "open": float(d["value"]), "high": float(d["value"]),
                 "low": float(d["value"]), "close": float(d["value"]), "volume": 0}
                for d in raw["data"] if d["value"] != "."
            ]
            series.sort(key=lambda x: x["date"])
            result = {
                "id": cid, "symbol": sym, "name": meta["name"],
                "unit": meta["unit"], "icon": meta["icon"],
                "exchange": meta["exchange"],
                "source": f"Alpha Vantage · {av_function} Commodity",
                "series": series,
            }
            save_cache(cache_key, result)
            return jsonify(result)
        except Exception as e:
            return jsonify({"error": str(e), "key_needed": API_KEY == "demo"}), 502
    else:
        # TIME_SERIES_DAILY para futuros (ZR, ZS, etc.)
        url = (
            f"https://www.alphavantage.co/query"
            f"?function=TIME_SERIES_DAILY&symbol={sym}&outputsize=full&datatype=json&apikey={API_KEY}"
        )
        try:
            r = requests.get(url, timeout=15)
            r.raise_for_status()
            raw = r.json()
            ts = raw.get("Time Series (Daily)")
            if not ts:
                raise ValueError(f"AV error: {raw.get('Note', raw.get('Information', raw))}")
            series = sorted([
                {"date": d,
                 "open": float(v["1. open"]), "high": float(v["2. high"]),
                 "low":  float(v["3. low"]),  "close": float(v["4. close"]),
                 "volume": int(float(v["5. volume"]))}
                for d, v in ts.items()
            ], key=lambda x: x["date"])
            result = {
                "id": cid, "symbol": sym, "name": meta["name"],
                "unit": meta["unit"], "icon": meta["icon"],
                "exchange": meta["exchange"],
                "source": f"Alpha Vantage · TIME_SERIES_DAILY ({sym})",
                "series": series,
            }
            save_cache(cache_key, result)
            return jsonify(result)
        except Exception as e:
            return jsonify({"error": str(e), "key_needed": API_KEY == "demo"}), 502

# ── Alpha Vantage: insumos (equities de referencia) ───────────────────────────

@app.route("/api/input/<iid>")
def input_price(iid):
    if iid not in INPUT_SYMBOLS:
        return jsonify({"error": "unknown input"}), 404
    sym = INPUT_SYMBOLS[iid]["sym"]
    cache_key = f"av_input_{sym}"
    cached = load_cache(cache_key, max_age_seconds=4 * 3600)
    if cached:
        return jsonify(cached)
    url = (
        f"https://www.alphavantage.co/query"
        f"?function=TIME_SERIES_DAILY&symbol={sym}&outputsize=full&datatype=json&apikey={API_KEY}"
    )
    try:
        r = requests.get(url, timeout=15)
        r.raise_for_status()
        raw = r.json()
        ts = raw.get("Time Series (Daily)")
        if not ts:
            raise ValueError(str(raw.get("Note", raw.get("Information", "API error"))))
        series = sorted([
            {"date": d, "close": float(v["4. close"]), "volume": int(float(v["5. volume"]))}
            for d, v in ts.items()
        ], key=lambda x: x["date"])
        meta = INPUT_SYMBOLS[iid]
        result = {"id": iid, "symbol": sym, "name": meta["name"],
                  "unit": meta["unit"], "source": "Alpha Vantage · Equity Daily", "series": series}
        save_cache(cache_key, result)
        return jsonify(result)
    except Exception as e:
        return jsonify({"error": str(e)}), 502

# ── Open-Meteo: clima actual ───────────────────────────────────────────────────

@app.route("/api/weather/current")
def weather_current():
    cache_key = "weather_current"
    cached = load_cache(cache_key, max_age_seconds=600)  # 10 min
    if cached:
        return jsonify(cached)
    results = []
    for loc in WEATHER_LOCS:
        try:
            url = (
                f"https://api.open-meteo.com/v1/forecast"
                f"?latitude={loc['lat']}&longitude={loc['lon']}"
                f"&current=temperature_2m,precipitation,wind_speed_10m,weather_code"
                f"&wind_speed_unit=kmh&timezone=auto"
            )
            r = requests.get(url, timeout=10)
            r.raise_for_status()
            j = r.json()
            c = j["current"]
            results.append({
                "region": loc["region"], "country": loc["country"],
                "lat": loc["lat"], "lon": loc["lon"],
                "temp": c["temperature_2m"],
                "precip": c["precipitation"],
                "wind": round(c["wind_speed_10m"]),
                "code": c["weather_code"],
            })
        except Exception as e:
            results.append({"region": loc["region"], "country": loc["country"], "error": str(e)})
    data = {"updated": datetime.utcnow().isoformat(), "locations": results,
            "source": "Open-Meteo Forecast API (open-meteo.com)"}
    save_cache(cache_key, data)
    return jsonify(data)

# ── Open-Meteo: historial climático 12 meses ──────────────────────────────────

@app.route("/api/weather/history")
def weather_history():
    cache_key = "weather_history"
    cached = load_cache(cache_key, max_age_seconds=6 * 3600)  # 6 horas
    if cached:
        return jsonify(cached)

    end_date   = datetime.utcnow().date()
    start_date = end_date - timedelta(days=365)
    results = []

    for loc in WEATHER_LOCS[:4]:  # 4 locaciones representativas
        try:
            url = (
                f"https://archive-api.open-meteo.com/v1/archive"
                f"?latitude={loc['lat']}&longitude={loc['lon']}"
                f"&start_date={start_date}&end_date={end_date}"
                f"&daily=precipitation_sum,temperature_2m_mean,temperature_2m_max,temperature_2m_min"
                f"&timezone=auto"
            )
            r = requests.get(url, timeout=20)
            r.raise_for_status()
            j = r.json()
            d = j["daily"]
            # Aggregate by month
            by_month = {}
            for i, t in enumerate(d["time"]):
                mk = t[:7]
                if mk not in by_month:
                    by_month[mk] = {"precip": [], "temp": [], "tmax": [], "tmin": []}
                if d["precipitation_sum"][i] is not None:
                    by_month[mk]["precip"].append(d["precipitation_sum"][i])
                if d["temperature_2m_mean"][i] is not None:
                    by_month[mk]["temp"].append(d["temperature_2m_mean"][i])
                if d["temperature_2m_max"][i] is not None:
                    by_month[mk]["tmax"].append(d["temperature_2m_max"][i])
                if d["temperature_2m_min"][i] is not None:
                    by_month[mk]["tmin"].append(d["temperature_2m_min"][i])
            monthly = []
            for mk in sorted(by_month.keys()):
                v = by_month[mk]
                monthly.append({
                    "month": mk,
                    "precip_mm": round(sum(v["precip"]), 1) if v["precip"] else None,
                    "temp_mean": round(sum(v["temp"]) / len(v["temp"]), 1) if v["temp"] else None,
                    "temp_max":  round(max(v["tmax"]), 1) if v["tmax"] else None,
                    "temp_min":  round(min(v["tmin"]), 1) if v["tmin"] else None,
                })
            results.append({"region": loc["region"], "country": loc["country"], "monthly": monthly})
        except Exception as e:
            results.append({"region": loc["region"], "country": loc["country"], "error": str(e)})

    data = {"updated": datetime.utcnow().isoformat(), "locations": results,
            "source": "ERA5 Reanalysis via Open-Meteo Archive API (archive-api.open-meteo.com)"}
    save_cache(cache_key, data)
    return jsonify(data)

# ── Info del servidor ──────────────────────────────────────────────────────────

@app.route("/api/status")
def status():
    cache_files = len([f for f in os.listdir(CACHE_DIR) if f.endswith(".json")])
    return jsonify({
        "status": "ok",
        "api_key_set": API_KEY != "demo",
        "api_key_preview": API_KEY[:4] + "****" if API_KEY != "demo" else "demo",
        "cache_entries": cache_files,
        "cache_dir": CACHE_DIR,
        "server_time": datetime.utcnow().isoformat(),
    })

# ── Arranque ───────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    host = "0.0.0.0"  # Render requiere 0.0.0.0

    if API_KEY == "demo":
        print("\n⚠️  AV_KEY no configurada — sin datos reales")
    else:
        print(f"\n✓ Clave Alpha Vantage: {API_KEY[:4]}****")

    print(f"✓ Servidor en http://{host}:{port}")
    app.run(debug=False, port=port, host=host)
