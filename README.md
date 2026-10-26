# k8s-fastapi-autoscaling

A deliberately plain app (FastAPI) that exists for **one reason**: to demonstrate
Horizontal Pod Autoscaling on a real cluster, driven by real CPU pressure, verified
by real assertions. It complements [`k8s-go-microservices`](https://github.com/thodorakos/k8s-go-microservices):
no Helm here, just plain multi-document YAML so a junior engineer can read every
manifest top to bottom and see exactly what the API server consumes.

## Architecture

```
        ┌─────────────── HPA (cpu > 50% → scale 1..5) ────────────────┐
        │                                                             ▼
 you ──curl──▶ | Service powinfo | ──▶ [ podinfo pod ] [ podinfo pod ] [ ... ]
        │      (ClusterIP)                       │                    │
 loadgen ─wget every 1s─────────────────────────┘                    └── metrics-server
```

## The app

`app/main.py` (stdlib + fastapi + psutil only):

| Endpoint      | Purpose                                                        |
|---------------|----------------------------------------------------------------|
| `GET /`       | pod identity: `service`, `version`, `pod` name                  |
| `GET /healthz`| readiness + liveness probe target (returns `{"ok":true,...}`)  |
| `GET /stats`  | live CPU load (`psutil`): stats used as the external proof     |
| `GET /burn?seconds=40` | busy-loops `sha256` for N seconds to *actually* peg CPU |

The burn endpoint triggers scaling with actual CPU load, the kind the HPA can
see: `Resource CPU utilization > 50%` against `requests: 100m / limits: 500m`.

Layout:

```
app/     FastAPI app, requirements.txt, Dockerfile (python:3.12-slim + uvicorn)
deploy/  00-namespace → 01-deployment → 02-service → 03-hpa → 04-loadgen → 05-monitoring (plain YAML)
scripts/validate.sh  full lifecycle: build → deploy → smoke → burn → scale up → scale down
```

## HPA contract (readable in one glance at `deploy/03-hpa.yaml`)

`minReplicas: 1`, `maxReplicas: 5`, CPU **utilization of requests** target **50%**,
driving `Deployment/powinfo`. `POD_NAME` is injected from `metadata.name` so every
response names the replica that served it.

## Run it

Requirements: docker, minikube (docker driver, `--container-runtime=docker` so the
same daemon that runs kubelet builds our image), kubectl.

```bash
minikube start -p p2-fastapi-hpa --driver=docker --cpus=2 --memory=1950 \
  --container-runtime=docker \
  --apiserver-ips=192.168.49.2 --apiserver-name=192.168.49.2

./scripts/validate.sh
```

(The `--apiserver-ips/--apiserver-name` pair is the WSL2 workaround for uppercase
hostnames breaking kubeadm cert SANs, minikube issue #9175.)

## Manual exploration

```bash
kubectl --context p2-fastapi-hpa -n hpa-demo get all,hpa
kubectl --context p2-fastapi-hpa -n hpa-demo port-forward svc/powinfo 19090:8080
curl http://127.0.0.1:19090/stats
curl -m 45 "http://127.0.0.1:19090/burn?seconds=40" &
watch kubectl --context p2-fastapi-hpa -n hpa-demo get hpa
```

## Monitoring: Prometheus + Grafana

`deploy/05-monitoring.yaml` adds a tiny monitoring stack in plain YAML: two Deployments, no operator, CRDs, or Helm. The app exposes two real metrics at `/metrics` (via `prometheus-client`): `powinfo_cpu_percent` (psutil gauge) and `powinfo_http_requests_total` (request counter with a `path` label).

Prometheus scrapes every `Running` pod labelled `app.kubernetes.io/name=powinfo` in `hpa-demo` every 10 seconds, plus itself. The TSDB sits in an `emptyDir` and keeps 12h of data; this is a demo, nothing here needs to survive a pod restart. Grafana reads the datasource from provisioning files and ships one dashboard, "powinfo autoscaling": CPU % per pod, requests/s per pod and path, and `up` per target. Login is admin/admin, set through env vars, fine for a screen on your own laptop.

It all runs in the `monitoring` namespace behind ClusterIP Services, so access goes through port-forward:

```console
kubectl --context p2-fastapi-hpa -n monitoring port-forward svc/grafana 19101:3000
# open http://127.0.0.1:19101   (user admin, password admin)
```

Prometheus, if you prefer raw queries:

```console
kubectl --context p2-fastapi-hpa -n monitoring port-forward svc/prometheus 19091:9090
curl "http://127.0.0.1:19091/api/v1/query?query=powinfo_cpu_percent"
```

`validate.sh` checks the whole chain on every run: both Deployments become ready, the `powinfo` scrape target reports up, Grafana lists its datasource and dashboard, and Prometheus answers queries with real app samples after the burn.

## Teardown

```bash
kubectl --context p2-fastapi-hpa -n hpa-demo delete all,ns hpa-demo --wait=false 2>/dev/null
kubectl --context p2-fastapi-hpa delete ns monitoring --wait=false 2>/dev/null
minikube delete -p p2-fastapi-hpa
```

## Validation results

Captured on minikube v1.39.0, Kubernetes v1.37.0, docker driver, 2 CPUs / 1950MB (WSL2 laptop).

```console
$ ./scripts/validate.sh
==> Verify tools
  ✓ platforms ok

==> Build image inside the minikube docker daemon
sha256:2abb8fb282d96d979907e553b890aad4db205eb27110d74c51022a4a74ea70b1
  ✓ powinfo:local built

==> Deploy manifests (namespace, deployment, service, HPA, loadgen, monitoring)
deployment "powinfo" successfully rolled out
  ✓ powinfo 1/1 ready
  ✓ prometheus + grafana ready

==> Enable metrics-server (required for HPA plumbing)
  ✓ metrics-server ok

==> Smoke /healthz and / via port-forward
  ✓ endpoints ok

==> Monitoring smoke: Prometheus targets + Grafana provisioning
  ✓ prometheus scrapes powinfo pods
  ✓ grafana healthy, datasource + dashboard provisioned (admin/admin)

==> HPA baseline
powinfo   Deployment/powinfo   cpu: 4%/50%   1     5     1     23m

==> Burn CPU: 4 parallel 40s burns (expect HPA to scale up)
  ✓ HPA scaled up to 4 replicas
powinfo   Deployment/powinfo   cpu: 299%/50%   1     5     4     25m

==> Sample response from among the replicas
"pod":"powinfo-69485d5448-zvmdq"

==> Prometheus has real app samples (not just its own self-scrape)
  ✓ /metrics endpoints flowing into prometheus

==> Scale down: wait back to 1 replica (cooldown ≤ 5 min)
  ✓ HPA scaled back to 1

==> All cluster objects
NAME                           READY   STATUS    RESTARTS   AGE
pod/loadgen                    1/1     Running   0
pod/powinfo-69485d5448-w26q8   1/1     Running   0

NAME              TYPE        CLUSTER-IP     PORT(S)    AGE
service/powinfo   ClusterIP   10.101.3.216   8080/TCP

NAME                                          REFERENCE            TARGETS     MINPODS   MAXPODS   REPLICAS
horizontalpodautoscaler.autoscaling/powinfo   Deployment/powinfo   cpu: 3%/50%   1         5         1

NAME                            READY   STATUS    AGE
pod/grafana-5d7c796b7-8gll7     1/1     Running   0
pod/prometheus-6844fb69b6-8tnz9 1/1     Running   0

NAME                TYPE        CLUSTER-IP       PORT(S)    AGE
service/grafana     ClusterIP   10.105.131.127   3000/TCP
service/prometheus  ClusterIP   10.104.154.138   9090/TCP

==> PASS ✅  autoscaling demo + monitoring works end to end
```

The run in numbers: 4% idle → burn 4×40s → **scale 1→4 replicas at 299% of target
50%** → Prometheus grabbed the burn as it happened (`powinfo_cpu_percent`) → cooldown
→ **back to 1 replica**, every step asserted with real exit codes.

