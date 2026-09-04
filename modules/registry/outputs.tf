output "repository_urls" {
  value = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "ARNs para acotar la politica de push del rol de CI."
  value       = [for v in aws_ecr_repository.this : v.arn]
}
