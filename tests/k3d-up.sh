#!/usr/bin/env bash
# Local rehearsal on k3d (k3s in docker): 1 server + 3 agents, RabbitMQ on host ports 5673/15673.
# Quirks for this host: docker network in the WARP-excluded range, host CA bundle mounted (TLS interception),
# relaxed kubelet eviction because the host disk is nearly full.
set -euo pipefail; export PATH=~/.local/bin:$PATH; cd "$(dirname "$0")/.."
docker network inspect k3d-net >/dev/null 2>&1 || docker network create --subnet 192.168.32.0/24 --gateway 192.168.32.1 k3d-net
k3d cluster create rmq --network k3d-net --servers 1 --agents 3 \
  -p "5673:30672@server:0" -p "15673:31672@server:0" \
  -v /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt@all \
  --k3s-arg '--kubelet-arg=eviction-hard=nodefs.available<1Gi,imagefs.available<1Gi@server:*' \
  --k3s-arg '--kubelet-arg=eviction-hard=nodefs.available<1Gi,imagefs.available<1Gi@agent:*' \
  --k3s-arg '--disable=traefik@server:*' --wait --timeout 300s
kubectl wait node --all --for=condition=Ready --timeout=180s
echo "== cert-manager"; kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml >/dev/null
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
echo "== operator"; sleep 5; kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/download/v2.23.0/cluster-operator.yml >/dev/null || { sleep 15; kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/download/v2.23.0/cluster-operator.yml >/dev/null; }
for i in $(seq 1 40); do kubectl -n rabbitmq-system get secret cluster-operator-webhook-server-cert >/dev/null 2>&1 && break; sleep 5; done
kubectl -n rabbitmq-system rollout restart deploy/rabbitmq-cluster-operator >/dev/null; kubectl -n rabbitmq-system rollout status deploy/rabbitmq-cluster-operator --timeout=300s
echo "== chart (published repo)"; helm repo add rabbitmq-ha https://cdmx-in.github.io/rabbitmq-ha >/dev/null 2>&1 || true; helm repo update rabbitmq-ha >/dev/null
sleep 10; helm upgrade --install rmq rabbitmq-ha/rabbitmq-ha -n rabbitmq --create-namespace -f values-kind.yaml | grep -E 'STATUS|CHART' || true
for i in $(seq 1 100); do R=$(kubectl -n rabbitmq get pods -l app.kubernetes.io/name=rmq --no-headers 2>/dev/null | grep -c '1/1 *Running' || true); [ "$R" = 3 ] && break; sleep 5; done
kubectl -n rabbitmq get pods -l app.kubernetes.io/name=rmq -o wide --no-headers | awk '{print "  ",$1,$2,$3,$7}'
U=$(kubectl -n rabbitmq get secret rmq-default-user -o jsonpath='{.data.username}' | base64 -d); P=$(kubectl -n rabbitmq get secret rmq-default-user -o jsonpath='{.data.password}' | base64 -d)
printf 'RMQ_USER=%s\nRMQ_PASS=%s\n' "$U" "$P" > .rmq-creds.env; chmod 600 .rmq-creds.env
for i in $(seq 1 30); do curl -sf -u "$U:$P" http://localhost:15673/api/overview -o /dev/null && break; sleep 3; done
curl -s -u "$U:$P" http://localhost:15673/api/vhosts | python3 -c 'import json,sys;[print("  vhost",v["name"],"default_queue_type=",v.get("default_queue_type")) for v in json.load(sys.stdin)]'
curl -s -u "$U:$P" -H 'Content-Type: application/json' -X PUT http://localhost:15673/api/queues/%2F/done -d '{"durable":true}' -o /dev/null -w '  declare done http=%{http_code}\n'
echo "== k3d-up done"
