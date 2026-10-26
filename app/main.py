import os
import time
import math
import random
import hashlib

import psutil
from fastapi import FastAPI, Response
from prometheus_client import Counter, Gauge, generate_latest

SERVICE = "powinfo"
VERSION = "v1"

app = FastAPI()

REQS = Counter("powinfo_http_requests_total", "HTTP requests served", ["path"])
CPU = Gauge("powinfo_cpu_percent", "Instantaneous process/node CPU % from psutil")


@app.middleware("http")
async def count_requests(request, call_next):
    REQS.labels(path=request.url.path).inc()
    return await call_next(request)


def pod_name() -> str:
    return os.getenv("POD_NAME", os.uname().nodename)


@app.get("/")
def root():
    return {
        "service": SERVICE,
        "version": VERSION,
        "pod": pod_name(),
        "message": "reserving capacity: this pod exists to be scaled",
    }


@app.get("/healthz")
def healthz():
    return {"ok": True, "pod": pod_name()}


@app.get("/stats")
def stats():
    return {
        "pod": pod_name(),
        "cpu_percent": psutil.cpu_percent(interval=0.2),
        "load_avg": psutil.getloadavg(),
    }


@app.get("/metrics")
def metrics():
    CPU.set(psutil.cpu_percent(interval=None))
    return Response(content=generate_latest(), media_type="text/plain; version=0.0.4")


@app.get("/burn")
def burn(seconds: int = 5):
    seconds = max(1, min(seconds, 60))
    pod = pod_name()
    nonce = random.getrandbits(64).to_bytes(16, "big")
    hashes_done = 0
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        nonce = hashlib.sha256(nonce).digest()
        hashes_done += 1
    return {"pod": pod, "burned_seconds": seconds, "hashes_done": hashes_done}
