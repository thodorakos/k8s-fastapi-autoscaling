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
deploy/  00-namespace → 01-deployment → 02-service → 03-hpa → 04-loadgen (plain YAML)
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

## Teardown

```bash
kubectl --context p2-fastapi-hpa -n hpa-demo delete all,ns hpa-demo --wait=false 2>/dev/null
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

==> Deploy manifests (namespace, deployment, service, HPA, loadgen)
deployment "powinfo" successfully rolled out
  ✓ powinfo 1/1 ready

==> Enable metrics-server (required for HPA plumbing)
  ✓ metrics-server ok

==> Smoke /healthz and / via port-forward
  ✓ endpoints ok

==> HPA baseline
powinfo   Deployment/powinfo   cpu: 4%/50%   1     5     1     2m38s

==> Burn CPU: 4 parallel 40s burns (expect HPA to scale up)
  ✓ HPA scaled up to 4 replicas
powinfo   Deployment/powinfo   cpu: 307%/50%   1     5     4     3m57s

==> Sample response from among the replicas
"pod":"powinfo-69485d5448-6fq44"

==> Scale down: wait back to 1 replica (cooldown ≤ 5 min)
  ✓ HPA scaled back to 1

==> All cluster objects
NAME                           READY   STATUS    RESTARTS
pod/loadgen                    1/1     Running
pod/powinfo-69485d5448-jpk7t   1/1     Running

NAME              TYPE        CLUSTER-IP       PORT(S)
service/powinfo   ClusterIP   10.109.117.195   8080/TCP

NAME                                          REFERENCE            TARGETS     MINPODS   MAXPODS   REPLICAS
horizontalpodautoscaler.autoscaling/powinfo   Deployment/powinfo   cpu: 3%/50%   1         5         1

==> PASS ✅  autoscaling demo works end to end
```

The run in numbers: 4% idle → burn 4×40s → **scale 1→4 replicas at 307% of target
50%** → cooldown → **back to 1 replica**, all asserted with real exit codes.

