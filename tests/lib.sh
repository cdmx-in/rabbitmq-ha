# shared helpers for failover tests: source this. Needs RMQ_USER/RMQ_PASS, MGMT (mgmt url), N8N (webhook base).
q() { curl -s -u "$RMQ_USER:$RMQ_PASS" "$MGMT/api/queues" | python3 -c '
import json,sys
for q in json.load(sys.stdin):
    print("  ",q["name"],"ready=",q["messages_ready"],"unacked=",q["messages_unacknowledged"],"leader=",q.get("leader","?").split("@")[-1].split(".")[0],"online=",len(q.get("online",[])),"consumers=",q["consumers"])'; }
nodes() { curl -s -u "$RMQ_USER:$RMQ_PASS" "$MGMT/api/nodes" | python3 -c 'import json,sys;print("   nodes:",", ".join(n["name"].split("@")[1].split(".")[0]+("" if n["running"] else "(DOWN)") for n in json.load(sys.stdin)))'; }
purge_done() { curl -s -u "$RMQ_USER:$RMQ_PASS" -X DELETE "$MGMT/api/queues/%2F/done/contents" -o /dev/null -w "   purge done http=%{http_code}\n"; }
# publish $1 batches of $2 msgs, $3 s apart; writes one line per batch to $PUBLOG
publish_bg() { PUBLOG=$(mktemp); ( for b in $(seq 1 $1); do curl -s -m 30 -H 'Content-Type: application/json' -X POST "$N8N/webhook/enqueue" -d "{\"count\":$2,\"batch\":\"$TEST-$b\"}" || echo '{"error":"curl failed"}'; echo; sleep $3; done ) > $PUBLOG 2>&1 & PUBPID=$!; }
published() { python3 -c 'import json,sys;t=0;f=0
for l in open(sys.argv[1]):
    l=l.strip()
    if not l: continue
    try: d=json.loads(l); t+=d.get("published",0); f+= 0 if "published" in d else 1
    except Exception: f+=1
print(t,f)' $PUBLOG; }
# wait until jobs drained and done >= expected, max $1 s
wait_drain() { for i in $(seq 1 $(( $1 / 5 ))); do read J D <<<"$(curl -s -u "$RMQ_USER:$RMQ_PASS" "$MGMT/api/queues" | python3 -c 'import json,sys;m={q["name"]:q["messages"] for q in json.load(sys.stdin)};print(m.get("jobs",-1),m.get("done",-1))')"; [ "$J" = 0 ] && [ "$D" -ge "$2" ] && { echo "   drained after ~$((i*5))s"; return; }; sleep 5; done; echo "   TIMEOUT waiting for drain (jobs=$J done=$D)"; }
report() { read P F <<<"$(published)"; D=$(curl -s -u "$RMQ_USER:$RMQ_PASS" "$MGMT/api/queues/%2F/done" | python3 -c 'import json,sys;print(json.load(sys.stdin)["messages"])'); echo "   RESULT $TEST: published=$P failed_batches=$F done=$D dups=$((D-P)) lost=$(( P>D ? P-D : 0 ))"; }
