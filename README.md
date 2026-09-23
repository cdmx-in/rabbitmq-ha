# RabbitMQ HA for n8n (Kubernetes)

Decision: **official RabbitMQ Cluster Operator** + this small chart. Not Bitnami: its chart is stuck on
RabbitMQ 4.1.3 and its versioned images moved to the unmaintained `bitnamilegacy` registry (up-to-date
images are now the paid Bitnami Secure Images). The operator is maintained by the RabbitMQ team, tracks
4.3.x, and does rolling upgrades/scale correctly.

HA model (RabbitMQ 4.x): classic mirrored queues are gone. HA = 3 brokers + **quorum queues**
(Raft, survive loss of 1 of 3). `default_queue_type = quorum` in rabbitmq.conf makes every queue n8n
declares replicated with no client-side arguments.

## Layout
- `chart/`            Helm chart: RabbitmqCluster CR (3 replicas, required pod anti-affinity, zone spread,
                      quorum default, pause_minority) + PodDisruptionBudget maxUnavailable=1.
- `values-kind.yaml`  local rehearsal values (NodePort, small resources).
- `values-prod.yaml`  production example (ClusterIP, SSD, pinned image).
- `n8n/`              producer + consumer workflows and the credential template used for the test.
- `kind.yaml`         local 4-node kind cluster used for the rehearsal.

## Production install
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/download/v2.23.0/cluster-operator.yml
helm upgrade --install rmq ./chart -n rabbitmq --create-namespace -f values-prod.yaml
kubectl -n rabbitmq get secret rmq-default-user -o jsonpath='{.data.password}' | base64 -d   # n8n credential
```
n8n RabbitMQ credential: host `rmq.rabbitmq.svc.cluster.local`, port 5672, vhost `/`, user/pass from the
secret above. Create a dedicated least-privilege user for n8n instead of default_user before go-live.

## Rehearsal results (kind, 3 brokers on 3 nodes, n8n 2.40.5)
- 500 jobs webhook -> `jobs` (quorum, 3 members) -> n8n trigger -> `done`: 500/500.
- 2000 jobs published while force-deleting the `jobs` leader pod: leader re-elected in <5s, all 2000
  publishes succeeded, 0 failed consumer executions, consumer trigger was deactivated on "Connection got closed unexpectedly" and n8n's activation retry brought it back within ~20s, 2019 in `done`
  (20 in-flight messages redelivered = at-least-once; make consumers idempotent on a job id).
- Broker pod came back and rejoined; cluster 3/3 running.

## n8n gotchas found
- The **send** node (`n8n-nodes-base.rabbitmq`) never creates a missing queue in 2.40.x (its
  `assertQueue` flag is stripped). Pre-declare queues on the broker (management API, or the
  Messaging Topology Operator `Queue` CRD in prod). The **trigger** does create the queue when
  `assertQueue: true` is set in its options.
- Trigger option `acknowledge: executionFinishesSuccessfully` is what gives you redelivery on failure.
- Deliveries are at-least-once; failover redelivers unacked messages.

## Local rehearsal env (this machine)
- kind cluster `rmq`; kubectl/helm/kind in `~/.local/bin`; RabbitMQ mgmt UI http://localhost:15673
  (creds from the rmq-default-user secret), AMQP localhost:5673.
- n8n test instance: docker `n8n-rmq-test`, http://localhost:5681, owner account created at first login.
- Host needed `fs.inotify.max_user_instances=8192` (now in /etc/sysctl.d/99-kind-inotify.conf) and
  images preloaded with `kind load docker-image` because the network's TLS interception is not trusted
  inside kind nodes.
- Tear down: `kind delete cluster --name rmq; docker rm -f n8n-rmq-test; docker volume rm n8n-rmq-test`.
