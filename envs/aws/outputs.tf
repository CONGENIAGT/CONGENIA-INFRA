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
