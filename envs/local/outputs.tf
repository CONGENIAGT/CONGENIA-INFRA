output "alb_name" {
  value = module.edge.alb_name
}

output "alb_dns_name" {
  value = module.edge.alb_dns_name
}

output "alb_local_url" {
  description = "Como se alcanza el ALB desde la maquina anfitriona."
  value       = "curl -H 'Host: ${module.edge.alb_name}.alb.localhost' http://localhost:4566/"
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "db_endpoint" {
  value = module.data.db_endpoint
}

output "redis_endpoint" {
  value = "${module.data.redis_address}:${module.data.redis_port}"
}

output "docs_bucket" {
  value = module.data.docs_bucket
}

output "ecs_cluster" {
  value = module.platform.cluster_name
}

output "target_group_arns" {
  value = module.edge.target_group_arns
}

output "ecr_repositories" {
  value = module.platform.ecr_repository_urls
}

output "alb_rule_arns" {
  value = module.edge.rule_arns
}

output "alb_routes" {
  value = module.edge.routes
}

output "waf_web_acl_arn" {
  value = module.security.web_acl_arn
}

output "flow_log_group" {
  value = module.security.flow_log_group
}

output "nacl_ids" {
  value = module.security.nacl_ids
}
