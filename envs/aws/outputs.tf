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
  value = { for k, v in data.aws_ecr_repository.this : k => v.repository_url }
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

output "sadc_client_secret_arn" {
  description = "ARN para recuperar el client secret usado por el smoke OAuth, sin exponer su valor."
  value       = aws_secretsmanager_secret.keycloak_sadc.arn
}

output "keycloak_admin_secret_arn" {
  description = "ARN del password del administrador bootstrap de Keycloak."
  value       = aws_secretsmanager_secret.keycloak_admin.arn
}

output "keycloak_medico_initial_secret_arn" {
  description = "ARN del password temporal del usuario medico.inicial; Keycloak obliga a cambiarlo al primer acceso."
  value       = aws_secretsmanager_secret.keycloak_medico_initial.arn
}

output "db_secret_arn" {
  description = "ARN del password de PostgreSQL para recuperacion operativa controlada."
  value       = aws_secretsmanager_secret.db.arn
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
  value = data.aws_ecr_repository.this["congenia/migrate"].repository_url
}

# ── TLS ─────────────────────────────────────────────────────────────────────

output "acm_validation_records" {
  description = <<-DESC
    Registros de validacion del certificado. Con `manage_dns = true` los crea
    Terraform y este output queda solo como diagnostico; con `manage_dns =
    false` son los CNAME que hay que pegar a mano en el proveedor DNS.
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

output "dns_managed" {
  description = "true cuando Terraform administra validacion y ALIAS en Route 53."
  value       = local.gestiona_dns
}
