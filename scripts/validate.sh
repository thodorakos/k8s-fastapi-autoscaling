#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE=${PROFILE:-p2-fastapi-hpa}
CTX=${PROFILE}
NS=hpa-demo
APP_PORT=8080
LOCAL_PORT=19090

die() { echo "✗ FAIL: $*" >&2; exit 1; }
say() { echo "==> $*"; }
kubectl() { command kubectl --context "$CTX" "$@"; }

say "Verify tools"
command -v docker >/dev/null 2>&1 || die "docker not installed"
command -v kubectl >/dev/null 2>&1 || die "kubectl not installed"
command -v minikube >/dev/null 2>&1 || die "minikube not installed"
kubectl get nodes >/dev/null 2>&1 || die "cluster $PROFILE unreachable via kubectl (see README)"
echo "  ✓ platforms ok"

say "Build image inside the minikube docker daemon"
[[ -n $(docker ps 2>/dev/null) ]] || die "docker daemon not reachable"
eval "$(minikube -p "$PROFILE" docker-env --shell bash)"
docker build -q -t powinfo:local app || die "image build failed"
echo "  ✓ powinfo:local built"

say "Deploy manifests (namespace, deployment, service, HPA, loadgen)"
kubectl apply -f deploy/ >/dev/null
kubectl rollout status deploy/powinfo -n "$NS" --timeout=5m
echo "  ✓ powinfo 1/1 ready"

say "Enable metrics-server (required for HPA plumbing)"
minikube -p "$PROFILE" addons enable metrics-server >/dev/null 2>&1 || die "metrics-server addon failed to enable"
kubectl wait --for=condition=available deploy -l k8s-app=metrics-server -n kube-system --timeout=5m >/dev/null || die "metrics-server never became available"
echo "  ✓ metrics-server ok"

say "Wait for metrics to be available to the HPA (cold cache can take ~30s)"
HOLD=${WAIT_TOP:-60}
sleep "$HOLD"

say "Smoke /healthz and / via port-forward"
kubectl port-forward svc/powinfo "$LOCAL_PORT:$APP_PORT" -n "$NS" >/dev/null 2>&1 &
PF=$!
sleep 3
trap 'kill $PF 2>/dev/null' EXIT

curl -fsS --max-time 5 "http://127.0.0.1:$LOCAL_PORT/healthz" | grep -q '"ok":true' || die "/healthz rejected"
curl -fsS --max-time 5 "http://127.0.0.1:$LOCAL_PORT/" | grep -q '"service":"powinfo"' || die "/ payload unexpected"
echo '  ✓ endpoints ok'

say "HPA baseline"
kubectl get hpa -n "$NS" --no-headers

say "Burn CPU: 4 parallel 40s burns (expect HPA to scale up)"
for _ in 1 2 3 4; do
  curl -sS --max-time 60 -m 60 "http://127.0.0.1:$LOCAL_PORT/burn?seconds=40" >/dev/null &
done

SCALE_OK=""
for _ in $(seq 1 24); do
  curr=$(kubectl get hpa powinfo -n "$NS" -o jsonpath='{.status.currentReplicas}')
  if [[ "${curr:-0}" -ge 3 ]]; then SCALE_OK=range_ok; break; fi
  sleep 10
done
if [[ -n "$SCALE_OK" ]]; then
  echo "  ✓ HPA scaled up to $curr replicas"
else
  die "HPA never scaled up (max 4 minutes waited)"
fi
kubectl get hpa -n "$NS" --no-headers

say "Sample response from among the replicas"
kubectl exec -n "$NS" loadgen -- wget -q -O - http://powinfo:8080/ | grep -o '"pod":"[^"]*"'

say "Scale down: wait back to 1 replica (cooldown ≤ 5 min)"
SD=""
for _ in $(seq 1 36); do
  curr=$(kubectl get hpa powinfo -n "$NS" -o jsonpath='{.status.currentReplicas}')
  if [[ "${curr:-9}" -eq 1 ]]; then SD=down_ok; break; fi
  sleep 10
done
[[ -n "$SD" ]] || die "HPA never scaled back down"
echo "  ✓ HPA scaled back to 1"

say "All cluster objects"
kubectl get all,hpa -n "$NS"

say "PASS ✅  autoscaling demo works end to end"
