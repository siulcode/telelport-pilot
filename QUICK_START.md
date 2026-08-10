# Quick start

From an empty AWS account to an HTTPS site on a three-node kubeadm cluster.

`./bootstrap.sh --all` measured **7m 09s** for steps 1 and 3 together; onboarding
a user and deploying the app add two or three minutes on top. Most of the wall
clock is nodes pulling container images, so a slow day runs longer.

## Prerequisites

- `aws` CLI v2, authenticated — check with `aws sts get-caller-identity`
- `kubectl` **within one minor of v1.36** — `kubectl version` after step 3.
  Kubernetes supports only ±1 skew; an older client mostly works and then fails
  in confusing ways (a v1.23 client segfaulted during testing).
- `ssh`, `scp`, `curl`, `openssl`

Nothing else. No Node, no Python, no `cdk bootstrap`, no Helm.
Running cost is ~$2.59/day — tear it down when idle.

---

## 1. Infrastructure — ~3 min

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

## 3. Cluster and platform — ~4 min

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
curl -sI http://nginx.demo | head -2        # permanent redirect to HTTPS
curl -s https://nginx.demo                  # fails: CA is not in the system store
kubectl --kubeconfig=users/viewer-user/kubeconfig -n demo \
  scale deploy/nginx --replicas=5           # 403: viewers cannot deploy
```

The deployer cannot read the TLS key either — cert-manager created the Secret,
Traefik consumes it, and nobody who deploys the app can see it:

```bash
kubectl --kubeconfig=users/deployer-user/kubeconfig -n demo get secret nginx-tls
```

## 7. Show the network boundary

`--cluster` applied a default-deny ingress policy in `demo`, with one hole for
Traefik. Prove it from inside the namespace:

```bash
kubectl -n demo run intruder --rm -i --restart=Never --image=curlimages/curl \
  -- -s --max-time 5 http://nginx
```

It times out — a pod sitting in the same namespace cannot reach nginx, only
Traefik can. Now see the verdict. `--cluster` already installed the `hubble` CLI
on the control plane, so no local install is needed:

```bash
ssh -i .ssh/teleport-k8s.pem ubuntu@<CP_EIP> \
  'hubble observe --server $(kubectl -n kube-system get svc hubble-relay \
     -o jsonpath="{.spec.clusterIP}"):80 --namespace demo --verdict DROPPED --last 20'
```

```
demo/intruder:42114 <> demo/nginx-7979b968bd-gdxbn:8080  Policy denied  DROPPED
```

Named source, named destination, the port, and the verdict. Swap
`--verdict DROPPED` for `--verdict FORWARDED` and you see Traefik's traffic
allowed through the one hole the policy leaves open.

If you would rather run it locally, install the Hubble CLI and port-forward
instead — `kubectl -n kube-system port-forward svc/hubble-relay 4245:80` then
`hubble observe --server localhost:4245 ...`.

The deployer cannot open that hole either — the policy is admin-owned:

```bash
kubectl --kubeconfig=users/deployer-user/kubeconfig -n demo \
  delete networkpolicy default-deny-ingress     # 403
```

Same least-privilege argument as the TLS Secret, one layer down: you can ship
the app, you cannot loosen what contains it.

---

## Optional — probe the ingress path alone

```bash
kubectl apply -f apps/probe.yml
curl -sI http://nginx.demo          # expect HTTP/1.1 200 OK
kubectl delete -f apps/probe.yml
```

A bare nginx pod binding `:80` on worker01. Useful for isolating DNS, the
Elastic IP, and Cilium's portmap chaining from anything Traefik does.

## Optional — the GitOps layer

Separate from everything above, and not included in `--all`:

```bash
./bootstrap.sh --deploy-gitops
```

Installs Argo CD namespace-scoped (no ClusterRoles), grants it a Role in
`demo-gitops` only, and points it at `apps/gitops/manifests` in this repo. It
prints what the controller can actually do, straight from the API server:

```
cluster-admin anywhere      : no
create clusterrolebinding   : no
read secrets in demo-gitops : no
read secrets in demo        : no
deploy in demo-gitops       : yes
deploy in demo              : no
```

Point `gitops.demo` at the **same ingress IP as `nginx.demo`** — the one on
worker01. It is easy to grab the control-plane IP by mistake, and since Traefik
only binds `:443` on worker01 you get a bare connection refusal rather than a
useful error:

```bash
sudo sh -c 'printf "%s\n" "<INGRESS_EIP>  gitops.demo" >> /etc/hosts'
```

```bash
curl --cacert .build/ca.crt https://gitops.demo
```

Same Traefik, same CA, different delivery. To see git act as the source of
truth, scale the Deployment by hand and watch it revert within ~10 seconds:

```bash
kubectl -n demo-gitops scale deploy/gitops-nginx --replicas=5
kubectl -n demo-gitops get deploy gitops-nginx -w
```

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

---

## Optional — see it in a browser

Everything above is reachable over the real ingress, but if you would rather
click than curl, forward the services to localhost. Run each in its own
terminal, or append `&` to background them:

```bash
kubectl -n demo        port-forward svc/nginx         8081:80
kubectl -n demo-gitops port-forward svc/gitops-nginx  8082:80
kubectl -n kube-system port-forward svc/hubble-ui     8083:80
kubectl -n argocd      port-forward svc/argocd-server 8084:443
```

| | |
|---|---|
| <http://localhost:8081> | the RBAC-deployed site |
| <http://localhost:8082> | the GitOps-delivered site |
| <http://localhost:8083> | Hubble — live flows and policy verdicts |
| <https://localhost:8084> | Argo CD |

Argo CD is `8084:443`, not `:80` — its server redirects HTTP to HTTPS, so
forwarding port 80 just yields a 307. Expect a certificate warning on that one;
it serves its own self-signed cert, unrelated to the demo CA. Log in as `admin`:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Note that port-forwarding talks to the Service directly, so it bypasses Traefik
and TLS entirely — useful for the two UIs, but the certificate chain only shows
up over the real ingress.

If you want `https://nginx.demo` to show a padlock instead of a warning, trust
the demo CA in your login keychain — and remove it afterwards, because its
private key lives in a throwaway cluster:

```bash
security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db .build/ca.crt
```

```bash
security delete-certificate -c teleport-k8s-demo-ca ~/Library/Keychains/login.keychain-db
```
