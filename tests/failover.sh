#!/usr/bin/env bash
# Failover scenarios against the local k3d cluster with n8n publishing (webhook) and consuming (trigger).
# usage: tests/failover.sh pod-kill|node-loss|rolling-upgrade|partition|all
set -uo pipefail; export PATH=~/.local/bin:$PATH; cd "$(dirname "$0")/.."
. ./.rmq-creds.env; export RMQ_USER RMQ_PASS MGMT=http://localhost:15673 N8N=http://localhost:5681; . tests/lib.sh
BATCHES=4; SIZE=500; GAP=3; EXPECT=$((BATCHES*SIZE))
leader_pod() { curl -s -u "$RMQ_USER:$RMQ_PASS" "$MGMT/api/queues/%2F/jobs" | python3 -c 'import json,sys;print(json.load(sys.stdin)["leader"].split("@")[1].split(".")[0])'; }
pod_node()  { kubectl -n rabbitmq get pod "$1" -o jsonpath='{.spec.nodeName}'; }
pod_ip()    { kubectl -n rabbitmq get pod "$1" -o jsonpath='{.status.podIP}'; }
start() { TEST=$1; echo; echo "### $TEST  $(date +%T)"; purge_done; publish_bg $BATCHES $SIZE $GAP; sleep 6; echo "   before:"; q; }
finish() { wait $PUBPID; wait_drain 300 $EXPECT; echo "   after:"; q; nodes; kubectl -n rabbitmq get pods -l app.kubernetes.io/name=rmq --no-headers | awk '{print "   ",$1,$2,$3,$4}'; report; }

pod_kill() { start pod-kill; L=$(leader_pod); echo "   killing jobs leader $L"; kubectl -n rabbitmq delete pod $L --grace-period=0 --force >/dev/null 2>&1; sleep 5; q; finish; }

node_loss() { start node-loss; L=$(leader_pod); N=$(pod_node $L); echo "   stopping node $N (hosts jobs leader $L)"; docker stop $N >/dev/null; sleep 10; q
  wait $PUBPID; echo "   publisher finished while node down:"; published | awk '{print "   published="$1" failed_batches="$2}'; wait_drain 240 $EXPECT; echo "   while node down:"; q; nodes
  echo "   starting node $N"; docker start $N >/dev/null; for i in $(seq 1 60); do kubectl get node $N --no-headers 2>/dev/null | grep -q ' Ready' && break; sleep 5; done
  for i in $(seq 1 60); do curl -s -u "$RMQ_USER:$RMQ_PASS" "$MGMT/api/nodes" | python3 -c 'import json,sys;sys.exit(0 if all(n["running"] for n in json.load(sys.stdin)) else 1)' && break; sleep 5; done; PUBPID=; finish; }

rolling_upgrade() { start rolling-upgrade; echo "   helm upgrade image -> rabbitmq:4.3.6-management"; helm upgrade rmq rabbitmq-ha/rabbitmq-ha -n rabbitmq -f values-kind.yaml --set image=rabbitmq:4.3.6-management >/dev/null
  wait $PUBPID; for i in $(seq 1 90); do kubectl -n rabbitmq rollout status sts/rmq-server --timeout=5s >/dev/null 2>&1 && break; sleep 5; done; kubectl -n rabbitmq rollout status sts/rmq-server --timeout=10s 2>&1 | tail -1
  kubectl -n rabbitmq get pods -l app.kubernetes.io/name=rmq -o jsonpath='{range .items[*]}   {.metadata.name} {.spec.containers[0].image}{"\n"}{end}'; PUBPID=; finish; }

partition() { start partition; L=$(leader_pod); PEERS=$(kubectl -n rabbitmq get pods -l app.kubernetes.io/name=rmq -o jsonpath='{range .items[*]}{.metadata.name}={.status.podIP} {end}' | tr ' ' '\n' | grep -v "^$L=" | cut -d= -f2)
  EXC=$(for ip in $PEERS; do printf '"%s/32",' $ip; done); EXC="[${EXC%,}]"; echo "   isolating $L from peers $(echo $PEERS | tr '\n' ' ')"
  kubectl -n rabbitmq apply -f - >/dev/null <<EOP
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: partition-test}
spec:
  podSelector: {matchLabels: {statefulset.kubernetes.io/pod-name: $L}}
  policyTypes: [Ingress, Egress]
  ingress: [{from: [{ipBlock: {cidr: 0.0.0.0/0, except: $EXC}}]}]
  egress:  [{to:   [{ipBlock: {cidr: 0.0.0.0/0, except: $EXC}}]}]
EOP
  sleep 45; echo "   during partition:"; q; nodes; kubectl -n rabbitmq exec $L -c rabbitmq -- rabbitmq-diagnostics -q cluster_status 2>/dev/null | grep -A3 -iE 'Running Nodes|partition' | head -8 | sed 's/^/     /'
  wait $PUBPID; echo "   healing"; kubectl -n rabbitmq delete networkpolicy partition-test >/dev/null
  for i in $(seq 1 60); do curl -s -u "$RMQ_USER:$RMQ_PASS" "$MGMT/api/nodes" | python3 -c 'import json,sys;sys.exit(0 if all(n["running"] for n in json.load(sys.stdin)) else 1)' && break; sleep 5; done; PUBPID=; finish; }

case "${1:-all}" in pod-kill) pod_kill;; node-loss) node_loss;; rolling-upgrade) rolling_upgrade;; partition) partition;; all) pod_kill; node_loss; rolling_upgrade; partition;; esac
