import os
import time
import math
import random
import hashlib

import psutil
from fastapi import FastAPI

SERVICE = "powinfo"
VERSION = "v1"

app = FastAPI()


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
