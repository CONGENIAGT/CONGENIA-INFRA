output "role_arn" {
  description = "Se publica como variable de organizacion AWS_ROLE_ARN en GitHub."
  value       = aws_iam_role.ecr_push.arn
}

output "oidc_provider_arn" {
  value = local.oidc_arn
}
