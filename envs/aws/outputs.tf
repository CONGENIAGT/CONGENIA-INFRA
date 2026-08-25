output "alb_dns_name" {
  value = module.edge.alb_dns_name
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "db_endpoint" {
  value     = module.data.db_endpoint
  sensitive = true
}

output "docs_bucket" {
  value = module.data.docs_bucket
}

output "ecr_repositories" {
  value = module.platform.ecr_repository_urls
}

output "private_namespace" {
  value = aws_service_discovery_private_dns_namespace.this.name
}

output "waf_web_acl_arn" {
  value = module.security.web_acl_arn
}

output "flow_log_group" {
  value = module.security.flow_log_group
}

output "client_vpn_dns" {
  value = module.vpn.client_vpn_dns
}

output "region" {
  value = var.region
}

output "public_url" {
  description = "Punto de entrada publico. Cambia a https cuando el certificado queda emitido."
  value       = local.public_url
}

# ── Carga del esquema ───────────────────────────────────────────────────────
# Los consume scripts/migrate.sh (`make migrate`).

output "ecs_cluster" {
  value = module.platform.cluster_name
}

output "migrate_task_definition" {
  description = "ARN con revision: se ejecuta exactamente lo que declara el estado."
  value       = module.migrate.task_definition_arn
}

output "migrate_network_config" {
  description = "Listo para `aws ecs run-task --network-configuration`."
  value = jsonencode({
    awsvpcConfiguration = {
      subnets        = module.network.app_subnet_ids
      securityGroups = [module.network.app_sg_id]
      assignPublicIp = "DISABLED"
    }
  })
}

output "migrate_log_group" {
  value = module.platform.log_group_names["migrate"]
}

output "migrate_image_repository" {
  value = module.platform.ecr_repository_urls["congenia/migrate"]
}

# ── TLS ─────────────────────────────────────────────────────────────────────

output "acm_validation_records" {
  description = <<-DESC
    Registros que hay que crear a mano en name.com para que ACM emita el
    certificado. Vacio si no hay dominio configurado.
  DESC
  value = flatten([
    for cert in aws_acm_certificate.this : [
      for opcion in cert.domain_validation_options : {
        nombre = opcion.resource_record_name
        tipo   = opcion.resource_record_type
        valor  = opcion.resource_record_value
      }
    ]
  ])
}

output "acm_certificate_status" {
  description = "PENDING_VALIDATION hasta que el CNAME exista; luego ISSUED."
  value       = one(aws_acm_certificate.this[*].status)
}
