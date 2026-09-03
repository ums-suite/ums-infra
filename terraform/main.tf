# ums-infra: local/staging Kubernetes cluster bootstrap.
#
# Provisions a kind cluster, then installs the two cross-cutting pieces every other Helm chart in
# this repo assumes already exist: an ingress controller (ingress-nginx) and cert-manager
# (self-signed/local CA -- no real ACME, per docs/adr/0001-local-cluster-tool-kind.md; UMS is a
# solo/portfolio project with no cloud account, same reasoning the kart-commerce sibling project's
# own ADR-0001 records).
#
# The `platform-observability` and `service-chart` Helm charts under ../helm/ are deliberately NOT
# installed from here -- those are installed directly with `helm install` per the top-level
# README, so a hello-world deployment can be proven independently of a full `terraform apply`
# re-run.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.11"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "kind" {}

# --- Cluster -----------------------------------------------------------

resource "kind_cluster" "this" {
  name           = var.cluster_name
  node_image     = var.node_image != "" ? var.node_image : null
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      kubeadm_config_patches = [
        "kind: InitConfiguration\nnodeRegistration:\n  kubeletExtraArgs:\n    node-labels: \"ingress-ready=true\"\n"
      ]

      extra_port_mappings {
        container_port = 80
        host_port      = var.ingress_http_port
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 443
        host_port      = var.ingress_https_port
        protocol       = "TCP"
      }
    }

    dynamic "node" {
      for_each = range(var.worker_node_count)
      content {
        role = "worker"
      }
    }
  }
}

# --- Provider wiring: point helm/kubernetes at the freshly created cluster ---

provider "helm" {
  kubernetes = {
    host                   = kind_cluster.this.endpoint
    client_certificate     = kind_cluster.this.client_certificate
    client_key             = kind_cluster.this.client_key
    cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  }
}

provider "kubernetes" {
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
}

# --- Ingress controller (ingress-nginx) ---------------------------------
#
# Values mirror kind's own documented ingress recipe
# (https://kind.sigs.k8s.io/docs/user/ingress/): hostPort + NodePort instead of LoadBalancer (kind
# has no cloud LB), scheduled only on the node labeled ingress-ready=true (the control-plane node,
# labeled above). This is the "Load Balancer / Ingress" box in
# ums-platform/docs/architecture/container-diagram.md -- TLS termination and routing to the
# correct frontend or to ums-core, with no separate API gateway (that diagram's own "Why One API
# Container, Not a Gateway" section).

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [yamlencode({
    controller = {
      hostPort = {
        enabled = true
      }
      service = {
        type = "NodePort"
      }
      nodeSelector = {
        "kubernetes.io/os" = "linux"
        "ingress-ready"    = "true"
      }
      tolerations = [
        {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Equal"
          effect   = "NoSchedule"
        }
      ]
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "250m", memory = "256Mi" }
      }
    }
  })]

  depends_on = [kind_cluster.this]
}

# --- cert-manager --------------------------------------------------------
#
# CRDs installed via the chart's own `crds.enabled` value (current key; `installCRDs` is the
# deprecated predecessor). No real ACME issuer is configured here -- a self-signed local
# ClusterIssuer is applied separately below via kubectl, once the cert-manager webhook is actually
# ready (a raw `kubernetes_manifest` resource can't express this ordering cleanly because the CRD
# doesn't exist at plan time -- see the null_resource below).

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  timeout          = 300

  set = [
    {
      name  = "crds.enabled"
      value = "true"
    }
  ]

  values = [yamlencode({
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "100m", memory = "128Mi" }
    }
    webhook = {
      resources = {
        requests = { cpu = "25m", memory = "32Mi" }
        limits   = { cpu = "50m", memory = "64Mi" }
      }
    }
    cainjector = {
      resources = {
        requests = { cpu = "25m", memory = "32Mi" }
        limits   = { cpu = "50m", memory = "64Mi" }
      }
    }
  })]

  depends_on = [kind_cluster.this]
}

# --- Self-signed local ClusterIssuer -------------------------------------
#
# Writes the cluster's kubeconfig to a local file (git-ignored) and shells out to kubectl to apply
# the ClusterIssuer once cert-manager's webhook is ready. Requires `kubectl` on PATH (already a
# documented prerequisite in the top-level README) -- this sidesteps the well-known Terraform
# chicken-and-egg problem where a `kubernetes_manifest` resource for a CRD type needs that CRD to
# already exist at plan time.

resource "local_file" "kubeconfig" {
  content         = kind_cluster.this.kubeconfig
  filename        = "${path.module}/.kubeconfig-${var.cluster_name}"
  file_permission = "0600"
}

resource "null_resource" "selfsigned_cluster_issuer" {
  depends_on = [helm_release.cert_manager, local_file.kubeconfig]

  triggers = {
    manifest_sha = filesha256("${path.module}/manifests/selfsigned-cluster-issuer.yaml")
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = local_file.kubeconfig.filename
    }
    command = <<-EOT
      set -e
      kubectl wait --for=condition=Available --timeout=180s deployment/cert-manager-webhook -n cert-manager
      kubectl apply -f "${path.module}/manifests/selfsigned-cluster-issuer.yaml"
    EOT
  }
}
