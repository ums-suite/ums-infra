---
doc_type: adr
status: accepted
---

# ADR-0001: Use kind (Kubernetes-in-Docker) as the Local/Staging Cluster Tool

## Status

Accepted

## Context

`release/DEVELOPMENT_PLAN.md`'s Flow #1 ("Org & infra bootstrap") scopes `ums-infra` to
"Terraform/Kubernetes infrastructure for the UMS platform: PostgreSQL, Redis, object storage,
ingress/load balancer, Kubernetes cluster bootstrap for `ums-core` and the six front-end apps" —
the same class of decision the sibling `kart-commerce` project's own `kart-infra` ADR-0001 made
for a 13-microservice platform. `ums-requirements.md` frames UMS explicitly as "A Modular-Monolith
Engineering Project, Built the Same Rigorous Way as kart-commerce" — a real Kubernetes deployment
story is part of that rigor, not optional scaffolding.

No standards doc anywhere in this platform picks a target deploy environment for local/staging
development. This is a solo portfolio project with no cloud account and no budget to provision a
real AWS/GCP/Azure cluster (mirroring `kart-infra`'s own ADR-0001 context exactly). A
cluster-bootstrap decision still has to be made to unblock every later flow that deploys something
(`ums-core`, `UMS.Workers`, six `ums-*-web` frontends — none of which have any code yet), so this
ADR makes the engineering-default call rather than blocking on an assumption nobody upstream has
resolved.

The candidates for a local Kubernetes cluster are **kind**, **k3d**, and **minikube**. All three
run free, on Docker, with no cloud account. The deciding factors are identical to `kart-infra`'s
own comparison — UMS's smaller topology (one backend deployable, one worker, six frontends, no
gateway, no message broker; see `container-diagram.md`) doesn't change which tool wins, only how
many nodes are worth provisioning (see Decision, below):

| Criterion | kind | k3d | minikube |
|---|---|---|---|
| Config format | Declarative YAML (`Cluster` config, `kind.x-k8s.io/v1alpha4`) consumed directly by the CLI and by a Terraform provider | Declarative YAML, but wraps k3s (a stripped-down distribution), not stock Kubernetes | Primarily CLI-flag driven; declarative config is less first-class |
| Multi-node support | Native, first-class (`nodes:` list — control-plane + N workers in one config) | Supported, but the underlying runtime (k3s) diverges from upstream Kubernetes in ways that matter for realistic topology testing | Multi-node exists but is newer/less battle-tested than kind's |
| Governance | A `kubernetes-sigs` project — same org as `kubeadm`, uses stock upstream Kubernetes node images | Community project (independent of `kubernetes-sigs`), built on k3s (Rancher/SUSE) | `kubernetes-sigs` project, but historically VM-first (Docker driver is newer) |
| Terraform support | `tehcyx/kind` provider on the public Terraform Registry (real, verified, current release `v0.11.0`) | No comparably maintained first-party Terraform provider | No first-party Terraform provider; typically driven via `local-exec`/shell only |

kind wins on every axis that matters here: **scriptability** (its config is a plain YAML `Cluster`
manifest, so `kind/kind-cluster-config.yaml` can be checked in and diffed like any other config),
**realistic topology** (multi-node clusters using the same node image kubeadm would produce, not a
k3s substitution — important for proving `ums-core`'s stateless-replica/HPA model actually
schedules correctly, per `container-diagram.md`), and **automation fit** (a real Terraform
provider exists, so cluster lifecycle is Terraform-managed instead of shelling out to `kind create
cluster` from a script).

## Decision

Use **kind (Kubernetes-in-Docker)** as this project's local/staging Kubernetes cluster, provisioned
declaratively:

- `kind/kind-cluster-config.yaml` — the canonical kind `Cluster` manifest (**one control-plane node
  + one worker node**, with `extraPortMappings` for host ports 80/443 so an ingress controller is
  reachable from the host) for anyone who wants to stand the cluster up directly with the `kind`
  CLI. This is deliberately a smaller topology than `kart-infra`'s two-worker cluster: UMS is one
  `ums-core` deployable + one `UMS.Workers` + six frontends with no API gateway and no message
  broker (`container-diagram.md`), so one worker is enough to exercise real scheduling behavior
  (replica spread across nodes, a rolling deploy actually draining one node while serving from the
  other) without the resource cost of a bigger cluster that nothing in this platform's topology
  needs.
- `terraform/` — the `tehcyx/kind` Terraform provider expresses the equivalent topology in HCL
  (`kind_config` block) so `terraform apply` is the actual automated path; the standalone YAML file
  and the Terraform `kind_config` block describe the same topology but are two separate
  representations that must be kept in sync by hand — accepted as a small, visible cost (see
  Consequences).
- Helm (via the Terraform `helm` provider, and via the charts in `helm/`) is the packaging tool for
  everything installed on top of the cluster, consistent with `ums-conventions.md`'s Observability
  section naming a Grafana Loki/Tempo + Prometheus stack "per `ums-infra`."

This ADR explicitly does **not** target any real cloud provider (AWS/GCP/Azure). If a later release
needs a managed cluster (EKS/GKE/AKS), that is a new ADR, not an extension of this one — the
Terraform module boundary (`kind_cluster` resource, `helm`/`kubernetes` providers pointed at
whatever cluster exists) is intentionally the seam where that swap would happen.

## Consequences

- **Easier:** cluster teardown/recreate is a single `terraform apply`/`terraform destroy` cycle; no
  cloud spend, no cloud account, no IAM setup blocks anyone from running this repo; a two-node
  topology means Deployment replica scheduling, PodDisruptionBudgets, and basic node-level
  resilience all behave like a real cluster instead of a single-node stand-in — enough to prove
  `ums-core`'s stateless-replica/HPA model (`container-diagram.md`: "horizontally scaled via
  Kubernetes HPA, no local session state") without over-provisioning nodes nothing in this
  platform's topology needs.
- **Harder:** kind clusters do not survive a host reboot with the same running containers (the
  Docker containers backing the nodes need to be recreated), so this is explicitly a
  dev/CI-local/staging tool, not a production target — anyone reading this repo later must not
  mistake it for a production deployment story.
- **Risk accepted:** the kind CLI config (`kind/kind-cluster-config.yaml`) and the Terraform
  `kind_config` HCL block in `terraform/main.tf` encode the same node topology in two places with
  no single source of truth. If one is edited without the other, they drift silently. Mitigated by
  keeping the topology intentionally simple (one control-plane, one worker, one port-mapping pair)
  so drift is easy to spot on review; a future improvement would be generating the HCL block from
  the YAML file (or vice versa) if the topology grows more complex.
- **Revisit trigger:** if this project ever needs to demonstrate a real cloud deployment, or if
  Flow #33 ("Scale & hardening") finds one worker node insufficient to rehearse result-day load
  realistically, this ADR's scope (kind only, two nodes) is the reason a new ADR — not an edit to
  this one — should record that decision.
