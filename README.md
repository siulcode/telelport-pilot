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

| Node | Type | ~USD/hr |
|---|---|---|
| Control plane | `t3.medium` | 0.0416 |
| Worker ×2 | `t3.small` | 0.0208 each |
| **Total** | | **~0.083** |

Roughly two dollars a day if left running, plus EBS. `--destroy` when idle.

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

**Elastic IP.** A stop/start would otherwise change the public IP and invalidate
every `certSAN` and kubeconfig mid-week.

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
- **The nginx site:** resolved by a laptop `/etc/hosts` entry pointing at a
  worker's public IP, reached over a NodePort.

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

The nginx pod terminates TLS itself, using a cert-manager-issued `Secret`
mounted directly. Fewest moving parts, and it is the most literal reading of the
requirement.

Ingress NGINX is **not** used: SIG Network and the Security Response Committee
retired the project on 24 March 2026 — no releases, no bugfixes, no security
patches since. Deploying unmaintained software to terminate TLS would be the
wrong choice to defend at a security company. If ingress-style routing is added
later, Gateway API with cert-manager's gateway support is the current path.

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
├── infra/
│   └── infra.yaml        # CloudFormation: VPC, SG, key pair, EIP, 3 instances
├── scripts/
│   └── lib.sh            # logging, preflight, SSH, stack-output helpers
└── node/                 # scripts executed on the instances (phase 2)
```
