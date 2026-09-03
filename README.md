# ums-infra

Terraform/Kubernetes cluster bootstrap for UMS's local/staging environment
(`release/DEVELOPMENT_PLAN.md` Flow #1, "Org & infra bootstrap"). This repo owns the cluster
itself and everything cross-cutting installed on top of it — PostgreSQL, Redis, and object storage
run as plain containers via `ums-devops`'s `docker-compose.yml` for the fast day-to-day dev loop
(see that repo), while this repo proves the same platform deployed to a real Kubernetes cluster.
Application code (`ums-core`, `UMS.Workers`, the six `ums-*-web` frontends) never lives here — each
lives in its own repo.

See [`docs/adr/0001-local-cluster-tool-kind.md`](docs/adr/0001-local-cluster-tool-kind.md) for why
**kind** (not k3d/minikube, not a real cloud provider) is this project's cluster tool, and why its
topology (one control-plane + one worker node) is smaller than a many-microservice platform's.

## Status

Cluster bootstrap (Terraform + kind + ingress-nginx + cert-manager), the shared observability
Helm chart, and the generic `service-chart` are real and usable **now** — see the verification
section below, including a real `helm template` render against the bundled hello-world example.
Per-deployable `values-<name>.yaml` files, and actually deploying `ums-core`/`UMS.Workers`/any
`ums-*-web` frontend with this chart, happen as each of those repos reaches a deployable state
(later `release/DEVELOPMENT_PLAN.md` flows) — every one of them is still "Not Started."

## Repository layout

| Path | Purpose |
|---|---|
| `kind/kind-cluster-config.yaml` | Canonical `kind` `Cluster` manifest — one control-plane + one worker node. Standalone, human-runnable path (no Terraform). |
| `terraform/` | Provisions the same topology via the `tehcyx/kind` provider, then installs ingress-nginx and cert-manager. The automated path. |
| `helm/platform-observability/` | The shared Grafana + Loki + Tempo + Prometheus stack, installed once per cluster. |
| `helm/service-chart/` | Generic, reusable chart every one of UMS's eight deployables (`ums-core`, `UMS.Workers`, six frontends) installs with — its own `values-<name>.yaml`, this chart's templates. |
| `docs/adr/` | Infra-scoped architecture decisions (currently just ADR-0001). |

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (kind runs cluster nodes as Docker containers)
- [`kind`](https://kind.sigs.k8s.io/) — only needed if standing the cluster up directly with the CLI instead of Terraform
- [`terraform`](https://developer.hashicorp.com/terraform/install) >= 1.6.0
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/) — required even in the Terraform path (the self-signed `ClusterIssuer` is applied via a `kubectl`-shelling `local-exec` provisioner, see `terraform/main.tf`)
- [`helm`](https://helm.sh/docs/intro/install/) >= 3.2

## Quickstart

### 1. Provision the cluster + ingress + cert-manager

```bash
cd terraform
terraform init
terraform apply
```

This creates the kind cluster (`ums-platform` by default), then installs `ingress-nginx` (hostPort
+ NodePort, no cloud LoadBalancer — see the ADR) and `cert-manager`, then applies a self-signed
local `ClusterIssuer` (`selfsigned-local-ca`) once cert-manager's webhook is ready.

Export the generated kubeconfig so `kubectl`/`helm` target this cluster:

```bash
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kubectl get nodes   # sanity check: 1 control-plane + 1 worker node, both Ready
```

Prefer the standalone path (no Terraform)? `kind create cluster --name ums-platform --config
../kind/kind-cluster-config.yaml` — see that file's header for the teardown command. You still need
to install ingress-nginx/cert-manager yourself in that path; Terraform is what automates it.

### 2. Install the shared observability stack

```bash
cd ../helm/platform-observability
helm dependency build
helm install platform-observability . --namespace observability --create-namespace
```

Grafana admin password (auto-generated, never hardcoded):

```bash
kubectl get secret -n observability platform-observability-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

`kubectl port-forward -n observability svc/platform-observability-grafana 3000:80` then open
`http://localhost:3000` — Loki and Tempo are pre-wired as datasources with trace-to-logs
correlation, matching `ums-conventions.md`'s Observability section.

### 3. Deploy a workload

```bash
cd ../service-chart
helm install <name> . --namespace <name> --create-namespace \
  -f values-<name>.yaml   # each of ums-core/UMS.Workers/each frontend owns its own override file
```

To prove the whole path end-to-end without any real UMS image built yet, deploy the bundled
hello-world example instead:

```bash
helm install hello-world . -f examples/hello-world-values.yaml
echo "127.0.0.1 hello-world.local" | sudo tee -a /etc/hosts
curl -k https://hello-world.local/
```

See [`helm/service-chart/README.md`](helm/service-chart/README.md) for every value this chart
exposes (ingress, autoscaling, PodDisruptionBudget, the Prometheus `ServiceMonitor`, health-probe
types, etc.), and worked examples for both `ums-core`'s shape (autoscaling + PDB, since it's the
one stateless HPA-scaled deployable per `container-diagram.md`) and a frontend's simpler shape.

### 4. Tear down

```bash
cd terraform
terraform destroy
```

kind clusters do not survive a host reboot with the same running containers — this is a
dev/CI-local/staging tool, never a production target (see the ADR's Consequences section).

## Verifying the cluster is healthy

```bash
kubectl get nodes                                     # 1 control-plane + 1 worker, both Ready
kubectl get pods -A                                   # everything Running/Completed
kubectl get clusterissuer selfsigned-local-ca          # Ready: True
kubectl get ingress -A                                 # ADDRESS populated once ingress-nginx is up
```

## Why this repo is simpler than a typical microservices `infra` repo

UMS is **one backend deployable** (`ums-core`) + **one background worker** (`UMS.Workers`) + **six
independent Angular frontends** — not a fleet of N microservices behind a gateway
(`container-diagram.md`, "Why One API Container, Not a Gateway + N Services"). Concretely:

- **One `service-chart`, reused eight times**, not one Helm chart per backend module — `ums-core`
  hosts all 18 modules in-process (ADR-0001 in `ums-platform`), so there's exactly one backend
  Deployment to template.
- **No gateway chart, no gateway routing config.** `ums-infra`'s ingress-nginx terminates TLS and
  routes to the correct frontend or to `ums-core` directly; module routing/auth/rate-limiting all
  happen inside `ums-core`'s own ASP.NET Core pipeline.
- **A two-node cluster is enough** (ADR-0001) — no 13-service topology to spread across many
  workers.

## Verification performed

- Every workflow-adjacent YAML/HCL file here parses: `terraform fmt -check` and `terraform
  validate` (with `terraform init -backend=false`) both run clean in `terraform/`.
- `helm lint` passes for both `helm/platform-observability` and `helm/service-chart`.
- `helm template` against `helm/service-chart` with `examples/hello-world-values.yaml` renders a
  complete, valid `Deployment`/`Service`/`Ingress`/`ServiceAccount` manifest set.
- **Not verified in this environment:** `kind`/`docker`-backed `terraform apply` (standing up a
  real cluster) and `helm dependency build`/`helm install` against a live cluster — `kind`,
  `terraform`, and `helm` CLIs are not installed here (only `docker`/`docker compose` are). See
  `ums-devops/README.md` for what *was* verified end-to-end (the local dev infra + observability
  Docker Compose stacks). `terraform validate`'s provider schema checks and `helm lint`/`helm
  template`'s manifest rendering are the strongest checks available without those tools; a
  full `terraform apply` + `kubectl get nodes` + `terraform destroy` cycle is the next thing to run
  once those CLIs are available.
