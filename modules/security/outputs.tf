output "web_acl_arn" {
  value = var.enable_waf ? aws_wafv2_web_acl.this[0].arn : null
}

output "flow_log_group" {
  value = var.enable_flow_logs ? aws_cloudwatch_log_group.flow[0].name : null
}

output "nacl_ids" {
  value = { for k, v in aws_network_acl.this : k => v.id }
}
