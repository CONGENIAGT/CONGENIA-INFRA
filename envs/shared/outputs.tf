output "ecr_repositories" {
  value = module.registry.repository_urls
}

output "ci_role_arn" {
  description = "Variable de organizacion AWS_ROLE_ARN en GitHub."
  value       = module.cicd.role_arn
}

output "ecr_registry" {
  description = "Variable de organizacion ECR_REGISTRY en GitHub."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

# Los cuatro nameservers que hay que pegar en name.com. Es el unico paso
# manual del bootstrap de DNS y solo se hace una vez.
output "name_servers" {
  value = var.manage_dns ? aws_route53_zone.public[0].name_servers : null
}

output "zone_id" {
  value = var.manage_dns ? aws_route53_zone.public[0].zone_id : null
}
