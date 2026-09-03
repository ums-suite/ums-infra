output "cluster_name" {
  description = "Name of the provisioned kind cluster."
  value       = kind_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = kind_cluster.this.endpoint
}

output "kubeconfig_path" {
  description = "Local path to the generated kubeconfig for this cluster. Export KUBECONFIG to this path, or run: kind export kubeconfig --name <cluster_name>."
  value       = local_file.kubeconfig.filename
}

output "kubeconfig" {
  description = "Raw kubeconfig contents for the cluster."
  value       = kind_cluster.this.kubeconfig
  sensitive   = true
}

output "ingress_nginx_namespace" {
  description = "Namespace ingress-nginx was installed into."
  value       = helm_release.ingress_nginx.namespace
}

output "cert_manager_namespace" {
  description = "Namespace cert-manager was installed into."
  value       = helm_release.cert_manager.namespace
}
