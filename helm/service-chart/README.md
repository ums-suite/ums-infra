# service-chart

Generic, reusable Helm chart for deploying any of UMS's **eight** deployables — `ums-core`,
`UMS.Workers`, or any of the six `ums-*-web` Angular frontends — to the local/staging kind cluster.
One chart, one `values-<deployable>.yaml` per deployable — nothing hand-rolls its own Kubernetes
manifests, per
[`docs/adr/0001-local-cluster-tool-kind.md`](../../docs/adr/0001-local-cluster-tool-kind.md).

This is deliberately the *same* chart reused eight times, not eight charts, and not one chart per
backend module — `ums-core` is a single deployable hosting all 18 modules in-process
(`container-diagram.md`, ADR-0001 in `ums-platform`), so there is exactly one backend Deployment to
template, not one per module.

## What it creates

`Deployment`, `Service`, `ServiceAccount` always; `Ingress`, `HorizontalPodAutoscaler`,
`PodDisruptionBudget`, `ConfigMap`, and a `ServiceMonitor` (for `platform-observability`'s
Prometheus) only when their respective `.enabled`/presence is set in values — see every default and
inline comment in [`values.yaml`](values.yaml).

## Usage

Each deployable keeps its own `values-<deployable>.yaml` in its own repo (or passed via `--set` in
CI) and installs against this chart from `ums-infra`:

```bash
# from a local checkout of this repo
helm install ums-core ./helm/service-chart \
  --namespace ums-core --create-namespace \
  -f values-ums-core.yaml
```

A minimal override file for `ums-core` — the one deployable that needs autoscaling (stateless, no
session affinity, `container-diagram.md`):

```yaml
image:
  repository: ghcr.io/ums-suite/ums-core
  tag: "1.0.0"

containerPort: 8080

probes:
  liveness:
    type: httpGet
    path: /health/live
  readiness:
    type: httpGet
    path: /health/ready

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

podDisruptionBudget:
  enabled: true
  minAvailable: 1

ingress:
  enabled: true
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-local-ca
  hosts:
    - host: api.ums.local
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: ums-core-tls
      hosts:
        - api.ums.local

serviceMonitor:
  enabled: true # only after platform-observability is installed (provides the CRD)
```

A minimal override for one of the six frontends (`ums-student-web`, say) needs no autoscaling or
PDB by default — traffic is far lower than `ums-core`'s and each app is independently deployed
(ADR-0016 in `ums-platform`):

```yaml
image:
  repository: ghcr.io/ums-suite/ums-student-web
  tag: "1.0.0"

containerPort: 4000

ingress:
  enabled: true
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-local-ca
  hosts:
    - host: student.ums.local
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: ums-student-web-tls
      hosts:
        - student.ums.local
```

See [`examples/hello-world-values.yaml`](examples/hello-world-values.yaml) for the values used to
smoke test this chart end-to-end against a real kind cluster with no real UMS image built yet.

## Security context

`podSecurityContext.runAsNonRoot: true` is the chart's default (Kubernetes Pod Security Standards
"restricted" profile). This requires the image to either declare a non-root `USER`, or the
deployable's own values file to set `podSecurityContext.runAsUser` explicitly — see
[`examples/hello-world-values.yaml`](examples/hello-world-values.yaml) for a worked example with a
third-party image that does neither on its own. Once `ums-core`/`UMS.Workers`'s own Dockerfiles
exist, add `USER $APP_UID` to the runtime stage (the .NET SDK base image already creates this
user) before deploying with this chart's defaults, or the pod fails with
`CreateContainerConfigError: container has runAsNonRoot and image will run as root`.

## Health probes

Probes default to a TCP check on `containerPort` (`probes.*.type: tcpSocket`) — safe for any
image, including `examples/hello-world-values.yaml`'s third-party one. Once `ums-core`/
`UMS.Workers` implement `/health/live` + `/health/ready` (mandatory per `ums-conventions.md`'s
Observability section — liveness is process-only, readiness checks Postgres + Redis reachability),
switch `probes.liveness.type`/`probes.readiness.type` to `httpGet` in that deployable's own values
file, matching the worked `ums-core` example above.

## Autoscaling & availability

`autoscaling.enabled`/`podDisruptionBudget.enabled` are both **off** by default — most of the
eight deployables (the six frontends, `UMS.Workers`) don't need them at this project's scale.
`ums-core` is the one deployable this chart's defaults exist to support turning both on for: it's
explicitly stateless and horizontally scaled via Kubernetes HPA with no session affinity
(`container-diagram.md`), which is also the reason `ums-requirements.md` §10's result-day traffic
model calls for a PodDisruptionBudget alongside the HPA — a rolling deploy or node drain should
never take every `ums-core` replica down at once during a high-traffic window.
