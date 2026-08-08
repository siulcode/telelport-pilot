# Quick start

A three-node kubeadm cluster on AWS, from nothing, in about 20 minutes.

## Prerequisites

- `aws` CLI v2, authenticated — check with `aws sts get-caller-identity`
- `ssh`, `scp`, `curl`

Nothing else. No Node, no Python, no `cdk bootstrap`.
Running cost is ~$2.59/day — tear it down when idle.

## 1. Infrastructure — ~4 min

```bash
./bootstrap.sh --infra
```

VPC, security group, IAM role, two Elastic IPs, three instances. Your public IP
is detected automatically and becomes the only source allowed to reach SSH, the
API server, and NodePorts.

## 2. Add two hosts entries

Step 1 prints these with the real IPs. Copy them verbatim:

```bash
sudo sh -c 'printf "%s\n" "<CP_EIP>  k8s-api.internal" "<INGRESS_EIP>  nginx.demo" >> /etc/hosts'
```

The first makes the API certificate match; the second points the site hostname
at the ingress.

## 3. Cluster — ~13 min

```bash
./bootstrap.sh --cluster
```

Host prep runs on all three nodes in parallel, then `kubeadm init`, worker join,
and the CNI.

## 4. Verify

```bash
export KUBECONFIG=./.kube/config
kubectl get nodes
```

Three nodes `Ready`.

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
