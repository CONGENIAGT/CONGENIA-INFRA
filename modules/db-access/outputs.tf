output "access" {
  value = {
    instance_id         = aws_instance.relay.id
    security_group_id   = aws_security_group.relay.id
    document_name       = aws_ssm_document.tunnel.name
    keycloak_document   = one(aws_ssm_document.keycloak[*].name)
    operator_policy_arn = aws_iam_policy.operator.arn
    connection          = var.connection
  }
}
