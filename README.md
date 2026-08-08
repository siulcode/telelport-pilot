# kubeadm Kubernetes on AWS EC2

A three-node Kubernetes cluster — one control plane, two workers — built with
`kubeadm` directly. No distribution wrapper, no bootstrap abstraction.

> **On tooling.** CloudFormation provisions machines and Bash configures them.
> Neither is a Kubernetes installer. `kubeadm` remains the sole mechanism that
> creates the cluster. No Kubespray, k3s, RKE2, kind, or minikube is used
> anywhere in this repository.

---

## Quick start

```bash
cp config.env config.env.local   # optional: override defaults
./bootstrap.sh --all
```

Or run the phases independently:

```bash
./bootstrap.sh --infra      # VPC, SG, EIP, key pair, 3 instances
./bootstrap.sh --cluster    # OS prep, containerd, kubeadm, CNI
./bootstrap.sh --status     # what exists right now
./bootstrap.sh --destroy    # tear everything down
```

Every flag is safe to re-run. Running `--all` twice changes nothing.

**Prerequisites:** `aws` CLI v2 with credentials configured, plus `ssh`, `scp`,
and `curl`. Nothing else — no Node, no Python, no `cdk bootstrap`.

---

## Why the two phases are built differently

This is the central design decision, and it is deliberate.

| | Phase 1 — infrastructure | Phase 2 — cluster |
|---|---|---|
| Tool | CloudFormation | Bash over SSH |
| Model | Declarative | Imperative |
| Idempotency | By construction — the platform reconciles desired against actual | By artifact guard — `[[ -f /etc/kubernetes/admin.conf ]] \|\| kubeadm init` |
| Teardown | `delete-stack`, correctly ordered | `kubeadm reset` plus iptables flush |
| State | Stack Outputs | Files on disk that kubeadm itself owns |

CloudFormation is used where the platform already provides reconciliation. Bash
is used where it does not: CloudFormation cannot know whether `kubeadm init`
succeeded, so cluster bootstrap guards on the artifacts kubeadm writes.

Keeping `kubeadm` in plain shell also keeps it **visible**. Every command that
builds the cluster can be read directly in `scripts/`, with no indirection to
explain during the demo.

### Known limits

- CloudFormation idempotency is **stack-scoped, not resource-scoped**. A manual
  console edit to the security group will not be reverted on the next deploy;
  detecting that requires an explicit drift-detection call.
- `kubeadm init` is guarded, not truly reconciled. If the control plane is
  half-built, `--destroy` and rebuild rather than re-running `--cluster`.

---

## Cost

The exercise suggests free tier. Three nodes do not fit it: `kubeadm`'s
preflight requires 2 vCPU and roughly 1700MB free memory, so `t3.micro` fails
outright.

| Item | Detail | ~USD/hr |
|---|---|---|
| Control plane | `t3.medium` | 0.0416 |
| Worker ×2 | `t3.small` | 0.0208 each |
| EBS | 3 × 30GB gp3 | 0.0099 |
| Public IPv4 | 2 EIP + 1 auto-assigned | 0.0150 |
| **Total** | | **~0.108** |

Roughly **$2.59/day**, or **$18/week** if left running. `--destroy` when idle.

Note the IPv4 line: since February 2024 AWS bills every public IPv4 address at
$0.005/hr whether or not it is attached. Two of the three here are Elastic IPs
and are deliberate; see the design notes.

---

## Design notes

**Split-horizon API endpoint.** `controlPlaneEndpoint` is a hostname, not an IP.
It resolves to the private IP inside the VPC (via `/etc/hosts` seeded in
UserData) and to the Elastic IP from your laptop. Both addresses are in
`certSANs`, so one certificate serves both paths.

Set this on your laptop after `--infra`:

```
<ControlPlanePublicIp>  k8s-api.internal
```

`--status` prints the exact line.

**Two Elastic IPs.** One on the control plane: a stop/start would otherwise
change the public IP and invalidate every `certSAN` and kubeconfig mid-week. One
on `worker01`, which is the ingress entry point — the nginx site's hostname
resolves there.

The second EIP exists because there is no cloud-controller-manager in this
cluster, so a `Service` of `type: LoadBalancer` would sit `Pending` forever:
nothing is running that can call the ELB API. Installing `cloud-provider-aws`
would fix that and is entirely possible with kubeadm — it is a component nobody
installed, not a capability kubeadm lacks. It was rejected on two grounds: an
NLB costs ~$16/month against a brief that asks for no expense, and the IAM grant
it needs (create/delete load balancers, modify security groups, attach ENIs)
would land on the **node role**, where no workload isolation protects it. An
Elastic IP buys the same stable entry point for the price of an IPv4 address.

The tradeoff is that a single EIP on a single worker is a SPOF. So is the single
control plane. Both are acceptable for a POC and neither is hidden.

**Instance IAM role — SSM only.** Each node carries an instance profile with
`AmazonSSMManagedInstanceCore` and nothing else. That is enough for Session
Manager, which means port 22 and the key pair could be dropped entirely — a
better access story than distributing a `.pem`, and the same argument this
exercise makes about kubeconfigs one layer down.

Route53 permissions for a cert-manager DNS-01 solver are deliberately **not**
granted. kubeadm has no IRSA, so pods inherit the node role: every workload on
the box would get DNS-write. If the public-domain path is taken, that wants a
scoped credential delivered as a `Secret`, not a node-wide grant.

**Encrypted root volumes.** Account-default `aws/ebs` key. etcd lives on the
control plane volume, so this is every `Secret` in the cluster at rest.

**Static private IPs.** `10.0.1.10`, `.21`, `.22` are assigned explicitly so
`certSANs` and hostnames stay identical across rebuilds.

**One self-referencing security group rule.** Covers etcd `2379-2380`, kubelet
`10250`, controller-manager `10257`, scheduler `10259`, the NodePort range, and
CNI overlay traffic. Enumerating those individually is the reliable way to miss
one and lose an hour.

**Generated key pair.** CloudFormation creates the key and stores the private
half in SSM Parameter Store as a SecureString. `bootstrap.sh` retrieves it to
`.ssh/` at `0600`. A reviewer needs no pre-existing key, and nothing sensitive
is committed.

**AMI from SSM Public Parameters.** Resolved at deploy time rather than
hardcoded, so the template does not rot.

### Deliberate POC shortcuts

Called out here rather than hidden — each would change in production:

- **Workers hold public IPs.** Production would place them in a private subnet
  behind a bastion or SSM Session Manager.
- **`StrictHostKeyChecking=no`.** Instances are rebuilt constantly and host keys
  change every time.
- **Single control plane.** No etcd quorum, no HA. `controlPlaneEndpoint` is
  nevertheless set from the start, so adding control-plane nodes later does not
  require regenerating certificates.
- **No etcd backup.** A disk failure loses all cluster state.

---

## Phase 2: DNS and TLS

Two independent certificate systems are in play, and they are frequently
conflated. They are unrelated:

| | Purpose | Mechanism |
|---|---|---|
| **Client certs** | *Who is this user?* | `certificates.k8s.io` CSR API, signed by the cluster CA |
| **Server certs** | *Is this site trustworthy?* | cert-manager, issuing for the nginx site |

### DNS

The cluster has no public DNS name, which constrains the certificate story:

- **In-cluster:** CoreDNS handles service discovery. Nothing to configure.
- **API server:** `k8s-api.internal` via split-horizon `/etc/hosts`, above.
- **The nginx site:** a laptop `/etc/hosts` entry pointing at the **ingress
  Elastic IP** on `worker01`, where Traefik binds `:80` and `:443` directly.
  `--status` prints the line.

### TLS

**Default — cert-manager with a self-signed CA issuer.** A `SelfSigned` issuer
bootstraps a CA certificate, which becomes a `CA` `ClusterIssuer` that signs the
site's leaf certificate. Fully offline, deterministic, no rate limits, no domain
required. The demo shows the chain with `curl --cacert ca.crt`.

**Alternative — real domain plus Route 53 and ACME DNS-01.** Produces a publicly
trusted certificate. Requires a registered domain and an IRSA/instance role for
`cert-manager` to write TXT records. `PUBLIC_INGRESS_CIDR` in `config.env`
exists for this path; the HTTP-01 alternative needs port 80 open to the world,
which DNS-01 avoids.

The self-signed path is the default because it satisfies the requirement without
external dependencies. The tradeoff is stated explicitly rather than hidden.

> `nip.io` and similar wildcard-DNS services are avoided. Let's Encrypt rate
> limits are shared across every user of those domains, so issuance is
> unreliable at exactly the wrong moment.

### Terminating TLS

**Traefik terminates TLS**, using the cert-manager-issued `Secret`. The nginx
pod behind it serves plain HTTP on the cluster network only. The certificate
chain is unchanged — cert-manager still issues it, Traefik just consumes it.

The requirements say nothing about how the application is exposed. They specify
the certificate **issuer** (cert-manager) and are silent on the **terminator**,
so pod-level TLS, an Ingress, and a Gateway are all compliant readings. An
ingress controller was chosen because it gives one stable entry point for any
number of future routes, and because it makes the GitOps objective tractable —
a new site becomes an `Ingress` object rather than new infrastructure.

**On ingress-nginx.** It is not used here, and that is a choice rather than a
constraint — nothing in the requirements prohibits it. SIG Network and the
Security Response Committee retired the project on 24 March 2026: no releases,
no bugfixes, no security patches since. Deploying unmaintained software to
terminate TLS is difficult to defend at a security company. Traefik is
maintained, familiar, and CNI-agnostic. Gateway API via Cilium was the other
candidate and is noted under the CNI section.

### Cluster networking

Three decisions that are easy to conflate, made at different layers:

| Layer | Question | Choice |
|---|---|---|
| Entry point | How does traffic reach the cluster? | Elastic IP on `worker01` |
| Service dataplane | How does a Service forward packets? | kube-proxy, **iptables** mode |
| HTTP routing | Which hostname goes to which Service? | Traefik reading `Ingress` objects |

**CNI — Cilium.** Chosen over Calico and Flannel for two reasons. Flannel has no
NetworkPolicy support at all, which rules it out at a security company. Between
the remaining two, Cilium ships **Hubble**, which gives a live flow view with
per-flow policy verdicts — and the requirements ask that users be able to
*deploy, access and monitor* the application. `hubble observe --verdict DROPPED`
makes a denied connection visible in one command. Calico's equivalent
observability was historically the commercial tier; its open-source Whisker UI
narrows the gap but is newer and thinner.

**kube-proxy in iptables mode.** IPVS silently degrades to iptables if the
`ip_vs` kernel modules are not loaded — you would believe you were running IPVS
and not be. Cilium's `kubeProxyReplacement` is the more modern answer and was
rejected only because it changes how service routing is debugged: `iptables-save`
is common ground with any reviewer, `cilium bpf lb list` is not. That is a demo
consideration, not a technical one, and it is worth saying so out loud.

**Traefik on `hostPort`, not `hostNetwork`.** Both give a clean `:443` on the
node. `hostNetwork` puts the pod in the node's network namespace, which costs it
its pod identity: a `NetworkPolicy` selecting `app=traefik` silently will not
match, because the traffic appears to come from the node — and Hubble attributes
those flows to the host rather than to Traefik, losing the pod exactly where you
most want to see it. `hostPort` keeps Traefik on the pod network, so policy and
observability both behave as written.

The cost is one Cilium setting: `hostPort` needs either `kubeProxyReplacement`
or CNI chaining with the `portmap` plugin. The latter is used here, since it
preserves the iptables decision above. `hostNetwork` remains the fallback if it
misbehaves — that swap is a few lines of manifest, not a rebuild.

### User access

RBAC onboarding is deliberately **not** automated into `bootstrap.sh`. The
CSR workflow — generate key, submit a `CertificateSigningRequest`, approve,
extract, assemble a kubeconfig — is kept as a separate readable script and run
live. Automating it would hide both the mechanism and the operational toil, and
the toil is the substance of the "what is wrong with managing access this way"
discussion.

---

## Layout

```
.
├── bootstrap.sh          # dispatcher
├── config.env            # single source of truth
├── config.env.local      # optional, uncommitted, overrides the above
├── infra/
│   └── infra.yaml        # CloudFormation: VPC, SG, IAM, key pair, 2 EIPs, 3 instances
├── scripts/
│   └── lib.sh            # logging, preflight, SSH, stack-output helpers
├── node/                 # scripts executed on the instances (phase 2)
└── docs/
    └── DESIGN.md         # design decisions and tradeoffs
```
