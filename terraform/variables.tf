variable "cluster_name" {
  description = "Name given to the kind cluster (and its kubeconfig context)."
  type        = string
  default     = "ums-platform"
}

variable "node_image" {
  description = <<-EOT
    kindest/node image tag to pin the Kubernetes version (e.g. "kindest/node:v1.34.0").
    Leave empty to use kind's own current default node image.
  EOT
  type        = string
  default     = ""
}

variable "worker_node_count" {
  description = <<-EOT
    Number of worker nodes in addition to the single control-plane node. Defaults to 1 - UMS is
    one ums-core deployable + one UMS.Workers + six frontends with no gateway and no broker
    (release/DEVELOPMENT_PLAN.md Flow #1), a much smaller topology than a many-microservice
    platform, so one worker is enough to exercise real scheduling behavior without the resource
    cost of a bigger cluster.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.worker_node_count >= 1
    error_message = "At least one worker node is required for a realistic multi-node topology."
  }
}

variable "ingress_http_port" {
  description = "Host port mapped to the control-plane node's container port 80 (ingress-nginx HTTP)."
  type        = number
  default     = 80
}

variable "ingress_https_port" {
  description = "Host port mapped to the control-plane node's container port 443 (ingress-nginx HTTPS)."
  type        = number
  default     = 443
}

variable "ingress_nginx_chart_version" {
  description = "ingress-nginx Helm chart version (repo: https://kubernetes.github.io/ingress-nginx)."
  type        = string
  default     = "4.15.1"
}

variable "cert_manager_chart_version" {
  description = "cert-manager Helm chart version (repo: https://charts.jetstack.io)."
  type        = string
  default     = "v1.21.0"
}
