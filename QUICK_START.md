# Quick start

From nothing to an HTTPS site on a three-node kubeadm cluster, in about 25 minutes.

## Prerequisites

- `aws` CLI v2, authenticated — check with `aws sts get-caller-identity`
- `kubectl` **within one minor of v1.36** — `kubectl version` after step 3.
  Kubernetes supports only ±1 skew; an older client mostly works and then fails
  in confusing ways (a v1.23 client segfaulted during testing).
- `ssh`, `scp`, `curl`, `openssl`

Nothing else. No Node, no Python, no `cdk bootstrap`, no Helm.
Running cost is ~$2.59/day — tear it down when idle.

---

## 1. Infrastructure — ~4 min

```bash
./bootstrap.sh --infra
```

VPC, security group, IAM role, two Elastic IPs, three instances. Your public IP
is detected automatically and becomes the only source allowed to reach SSH, the
API server, and NodePorts.

## 2. Add two hosts entries

Step 1 prints these with the real IPs. The first makes the API certificate
match; the second points the site hostname at the ingress.

**On a rebuild the Elastic IPs change**, so remove any previous entries first —
appending would leave the stale line ahead of the new one, and the first match
in `/etc/hosts` wins:

```bash
sudo sh -c 'grep -vE "k8s-api\.internal|nginx\.demo" /etc/hosts > /tmp/h && cat /tmp/h > /etc/hosts'
```

Then add the current pair:

```bash
sudo sh -c 'printf "%s\n" "<CP_EIP>  k8s-api.internal" "<INGRESS_EIP>  nginx.demo" >> /etc/hosts'
```

`./bootstrap.sh --status` reprints both lines at any time. Nothing in
`--infra` or `--cluster` depends on this — it is for your `kubectl` and `curl`.

## 3. Cluster and platform — ~15 min

```bash
./bootstrap.sh --cluster
```

Host prep on all three nodes in parallel, `kubeadm init`, worker join, Cilium,
then cert-manager, the issuer chain, Traefik, and the `demo` namespace with its
two Roles. Ends by writing `.kube/config` and `.build/ca.crt`.

```bash
export KUBECONFIG=$PWD/.kube/config
kubectl get nodes
```

Three nodes `Ready`.

---

## 4. Onboard a user — the CSR workflow

Nothing is deployed by admin from here on. Issue a client certificate through
the `certificates.k8s.io` API and get a kubeconfig back:

```bash
./onboard-user.sh deployer-user demo-deployers 30
```

Seven steps, printed as it goes: private key → CSR → submit → approve → the
cluster CA signs → kubeconfig → verify. Lands in `users/deployer-user/`.

For a read-only persona:

```bash
./onboard-user.sh viewer-user demo-viewers 30
```

## 5. Deploy the site as that user

```bash
kubectl --kubeconfig=users/deployer-user/kubeconfig apply -f apps/nginx/nginx.yaml
kubectl --kubeconfig=users/deployer-user/kubeconfig -n demo rollout status deploy/nginx
```

ConfigMap, Deployment, Service, `Certificate`, and `Ingress` — all created by a
certificate-authenticated user scoped to one namespace, never by `admin.conf`.

## 6. Test it

```bash
curl --cacert .build/ca.crt https://nginx.demo
```

The page, over TLS, with a certificate cert-manager issued from the cluster's
own CA. Three things worth checking while you are here:

```bash
curl -sI http://nginx.demo | head -2        # 308 redirect to HTTPS
curl -s https://nginx.demo                  # fails: CA is not in the system store
kubectl --kubeconfig=users/viewer-user/kubeconfig -n demo \
  scale deploy/nginx --replicas=5           # 403: viewers cannot deploy
```

The deployer cannot read the TLS key either — cert-manager created the Secret,
Traefik consumes it, and nobody who deploys the app can see it:

```bash
kubectl --kubeconfig=users/deployer-user/kubeconfig -n demo get secret nginx-tls
```

---

## Optional — probe the ingress path alone

```bash
kubectl apply -f apps/probe.yml
curl -sI http://nginx.demo          # expect HTTP/1.1 200 OK
kubectl delete -f apps/probe.yml
```

A bare nginx pod binding `:80` on worker01. Useful for isolating DNS, the
Elastic IP, and Cilium's portmap chaining from anything Traefik does.

## Teardown

```bash
./bootstrap.sh --reset      # cluster only, instances stay up
./bootstrap.sh --destroy    # everything, including the stack
```

## If it fails

Per-node logs are in `.build/logs/<ip>.log`, and the last 20 lines print
automatically. Retry with `--reset` then `--cluster`.

Every flag is safe to re-run; `--all` twice changes nothing.

If SSH starts timing out, your public IP probably changed (VPN on/off) — re-run
`--infra` to refresh the security group.
