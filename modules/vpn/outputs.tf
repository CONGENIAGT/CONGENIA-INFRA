output "vpn_gateway_id" {
  value = var.enable_site_to_site ? aws_vpn_gateway.this[0].id : null
}

output "vpn_connection_id" {
  value = var.enable_site_to_site ? aws_vpn_connection.this[0].id : null
}

output "client_vpn_endpoint_id" {
  value = var.enable_client_vpn ? aws_ec2_client_vpn_endpoint.this[0].id : null
}

output "client_vpn_dns" {
  value = var.enable_client_vpn ? aws_ec2_client_vpn_endpoint.this[0].dns_name : null
}
