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

API_KEY = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("AV_KEY", "demo")
CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache")
os.makedirs(CACHE_DIR, exist_ok=True)

app = Flask(__name__, static_folder="static")

SYMBOLS = {
    "cafe":   {"sym": "KC",  "name": "Café Arábica",  "unit": "USD/libra",  "icon": "☕", "exchange": "ICE"},
    "maiz":   {"sym": "ZC",  "name": "Maíz",          "unit": "USc/bushel", "icon": "🌽", "exchange": "CBOT"},
    "arroz":  {"sym": "ZR",  "name": "Arroz",         "unit": "USD/cwt",    "icon": "🌾", "exchange": "CBOT"},
    "azucar": {"sym": "SB",  "name": "Azúcar #11",    "unit": "USD/libra",  "icon": "🎋", "exchange": "ICE"},
    "banano": {"sym": "ZS",  "name": "Soya (ref.)",   "unit": "USc/bushel", "icon": "🍌", "exchange": "CBOT"},
}

INPUT_SYMBOLS = {
    "urea":     {"sym": "CF",   "name": "CF Industries (urea ref.)",  "unit": "USD"},
    "potasio":  {"sym": "MOS",  "name": "Mosaic Co. (potasio ref.)",  "unit": "USD"},
    "petroleo": {"sym": "CL",   "name": "Petróleo WTI (diesel ref.)", "unit": "USD/barril"},
}

WEATHER_LOCS = [
    {"region": "Guatemala",  "lat": 14.64, "lon": -90.51, "country": "ca"},
    {"region": "Costa Rica", "lat":  9.93, "lon": -84.09, "country": "ca"},
    {"region": "Honduras",   "lat": 14.09, "lon": -87.21, "country": "ca"},
    {"region": "Colombia",   "lat":  4.71, "lon": -74.07, "country": "co"},
    {"region": "Venezuela",  "lat": 10.48, "lon": -66.88, "country": "ve"},
    {"region": "Ecuador",    "lat": -0.23, "lon": -78.52, "country": "ec"},
]

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

@app.after_request
def add_cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return resp

@app.route("/")
def index():
    return send_from_directory("static", "index.html")

@app.route("/static/<path:path>")
def static_files(path):
    return send_from_directory("static", path)

@app.route("/api/commodity/<cid>")
def commodity(cid):
    if cid not in SYMBOLS:
        return jsonify({"error": "unknown commodity"}), 404
    sym = SYMBOLS[cid]["sym"]
    cache_key = f"av_daily_{sym}"
    cached = load_cache(cache_key, max_age_seconds=4 * 3600)
    if cached:
        return jsonify(cached)
    COMMODITY_ENDPOINTS = {"KC": "COFFEE", "ZC": "CORN", "ZR": None, "SB": "SUGAR", "ZS": None}
    av_function = COMMODITY_ENDPOINTS.get(sym)
    meta = SYMBOLS[cid]
    if av_function:
        url = f"https://www.alphavantage.co/query?function={av_function}&interval=daily&datatype=json&apikey={API_KEY}"
        try:
            r = requests.get(url, timeout=15)
            r.raise_for_status()
            raw = r.json()
            if "data" not in raw:
                raise ValueError(str(raw))
            series = sorted([{"date": d["date"], "open": float(d["value"]), "high": float(d["value"]), "low": float(d["value"]), "close": float(d["value"]), "volume": 0} for d in raw["data"] if d["value"] != "."], key=lambda x: x["date"])
            result = {"id": cid, "symbol": sym, "name": meta["name"], "unit": meta["unit"], "icon": meta["icon"], "exchange": meta["exchange"], "source": f"Alpha Vantage {av_function}", series: series}
            save_cache(cache_key, result)
            return jsonify(result)
        except Exception as e:
            return jsonify({"error": str(e)}), 502
    else:
        url = f"https://www.alphavantage.co/query?function=TIME_SERIES_DAILY&symbol={sym}&outputsize=full&datatype=json&apikey={API_KEY}"
        try:
            r = requests.get(url, timeout=15)
            r.raise_for_status()
            raw = r.json()
            ts = raw.get("Time Series (Daily)")
            if not ts:
                raise ValueError(str(raw))
            series = sorted([{"date": d, "open": float(v["1. open"]), "high": float(v["2. high"]), "low": float(v["3. low"]), "close": float(v["4. close"]), "volume": int(float(v["5. volume"]))} for d, v in ts.items()], key=lambda x: x["date"])
            result = {"id": cid, "symbol": sym, "name": meta["name"], "unit": meta["unit"], "icon": meta["icon"], "exchange": meta["exchange"], "source": f"Alpha Vantage {sym}", "series": series}
            save_cache(cache_key, result)
            return jsonify(result)
        except Exception as e:
            return jsonify({"error": str(e)}), 502

@app.route("/api/input/<iid>")
def input_price(iid):
    if iid not in INPUT_SYMBOLS:
        return jsonify({"error": "unknown input"}), 404
    sym = INPUT_SYMBOLS[iid]["sym"]
    cache_key = f"av_input_{sym}"
    cached = load_cache(cache_key, max_age_seconds=4 * 3600)
    if cached:
        return jsonify(cached)
    url = f"https://www.alphavantage.co/query?function=TIME_SERIES_DAILY&symbol={sym}&outputsize=full&datatype=json&apikey={API_KEY}"
    try:
        r = requests.get(url, timeout=15)
        r.raise_for_status()
        raw = r.json()
        ts = raw.get("Time Series (Daily)")
        if not ts:
            raise ValueError(str(raw))
        series = sorted([{"date": d, "close": float(v["4. close"]), "volume": int(float(v["5. volume"]))} for d, v in ts.items()], key=lambda x: x["date"])
        meta = INPUT_SYMBOLS[iid]
        result = {"id": iid, "symbol": sym, "name": meta["name"], "unit": meta["unit"], "source": "Alpha Vantage", "series": series}
        save_cache(cache_key, result)
        return jsonify(result)
    except Exception as e:
        return jsonify({"error": str(e)}), 502

@app.route("/api/weather/current")
def weather_current():
    cache_key = "weather_current"
    cached = load_cache(cache_key, max_age_seconds=600)
    if cached:
        return jsonify(cached)
    results = []
    for loc in WEATHER_LOCS:
        try:
            url = f"https://api.open-meteo.com/v1/forecast?latitude={loc['lat']}&longitude={loc['lon']}&current=temperature_2m,precipitation,wind_speed_10m,weather_code&wind_speed_unit=kmh&timezone=auto"
            r = requests.get(url, timeout=10)
            r.raise_for_status()
            j = r.json()
            c = j["current"]
            results.append({"region": loc["region"], "country": loc["country"], "lat": loc["lat"], "lon": loc["lon"], "temp": c["temperature_2m"], "precip": c["precipitation"], "wind": round(c["wind_speed_10m"]), "code": c["weather_code"]})
        except Exception as e:
            results.append({"region": loc["region"], "country": loc["country"], "error": str(e)})
    data = {"updated": datetime.utcnow().isoformat(), "locations": results, "source": "Open-Meteo Forecast API"}
    save_cache(cache_key, data)
    return jsonify(data)

@app.route("/api/weather/history")
def weather_history():
    cache_key = "weather_history"
    cached = load_cache(cache_key, max_age_seconds=6 * 3600)
    if cached:
        return jsonify(cached)
    end_date = datetime.utcnow().date()
    start_date = end_date - timedelta(days=365)
    results = []
    for loc in WEATHER_LOCS[:4]:
        try:
            url = f"https://archive-api.open-meteo.com/v1/archive?latitude={loc['lat']}&longitude={loc['lon']}&start_date={start_date}&end_date={end_date}&daily=precipitation_sum,temperature_2m_mean,temperature_2m_max,temperature_2m_min&timezone=auto"
            r = requests.get(url, timeout=20)
            r.raise_for_status()
            j = r.json()
            d = j["daily"]
            by_month = {}
            for i, t in enumerate(d["time"]):
                mk = t[:7]
                if mk not in by_month:
                    by_month[mk] = {"precip": [], "temp": []}
                if d["precipitation_sum"][i] is not None:
                    by_month[mk]["precip"].append(d["precipitation_sum"][i])
                if d["temperature_2m_mean"][i] is not None:
                    by_month[mk]["temp"].append(d["temperature_2m_mean"][i])
            monthly = [{"month": mk, "precip_mm": round(sum(v["precip"]), 1) if v["precip"] else None, "temp_mean": round(sum(v["temp"]) / len(v["temp"]), 1) if v["temp"] else None} for mk in sorted(by_month.keys()) for v in [by_month[mk]]]
            results.append({"region": loc["region"], "country": loc["country"], "monthly": monthly})
        except Exception as e:
            results.append({"region": loc["region"], "country": loc["country"], "error": str(e)})
    data = {"updated": datetime.utcnow().isoformat(), "locations": results, "source": "ERA5 via Open-Meteo Archive API"}
    save_cache(cache_key, data)
    return jsonify(data)

@app.route("/api/status")
def status():
    cache_files = len([f for f in os.listdir(CACHE_DIR) if f.endswith(".json")])
    return jsonify({"status": "ok", "api_key_set": API_KEY != "demo", "api_key_preview": API_KEY[:4] + "****" if API_KEY != "demo" else "demo", "cache_entries": cache_files, "server_time": datetime.utcnow().isoformat()})

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    host = "0.0.0.0"
    if API_KEY == "demo":
        print("AV_KEY no configurada")
    else:
        print(f"Clave: {API_KEY[:4]}****")
    print(f"Servidor en http://{host}:{port}")
    app.run(debug=False, port=port, host=host)
