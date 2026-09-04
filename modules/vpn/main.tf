# =============================================================================
# Modulo: vpn
#
# Dos caminos distintos, que resuelven problemas distintos:
#
#   site-to-site  ->  la VPC habla con la red privada ajena donde esta la base
#                     de datos externa que consume AnalyticsService.
#   client vpn    ->  una persona del equipo alcanza RDS, la consola de
#                     RabbitMQ o Keycloak sin publicarlos en el ALB.
#
# Los dos vienen apagados por defecto y cada uno tiene un requisito previo
# distinto; los detalles estan en las variables del modulo.
# =============================================================================

# ── Sitio a sitio ───────────────────────────────────────────────────────────

resource "aws_vpn_gateway" "this" {
  count = var.enable_site_to_site ? 1 : 0

  vpc_id = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-vgw" })
}

resource "aws_customer_gateway" "this" {
  count = var.enable_site_to_site ? 1 : 0

  bgp_asn    = var.remote_bgp_asn
  ip_address = var.remote_gateway_ip
  type       = "ipsec.1"

  tags = merge(var.tags, { Name = "${var.name_prefix}-cgw" })
}

resource "aws_vpn_connection" "this" {
  count = var.enable_site_to_site ? 1 : 0

  vpn_gateway_id      = aws_vpn_gateway.this[0].id
  customer_gateway_id = aws_customer_gateway.this[0].id
  type                = "ipsec.1"
  static_routes_only  = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpn" })
}

resource "aws_vpn_connection_route" "this" {
  for_each = var.enable_site_to_site ? toset(var.remote_cidrs) : []

  vpn_connection_id      = aws_vpn_connection.this[0].id
  destination_cidr_block = each.value
}

# Las subredes privadas aprenden las rutas del otro extremo.
resource "aws_vpn_gateway_route_propagation" "this" {
  for_each = var.enable_site_to_site ? toset(var.private_route_table_ids) : []

  vpn_gateway_id = aws_vpn_gateway.this[0].id
  route_table_id = each.value
}

# ── Acceso de operadores ────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "client" {
  count = var.enable_client_vpn ? 1 : 0

  name              = "/vpn/${var.name_prefix}/client"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_cloudwatch_log_stream" "client" {
  count = var.enable_client_vpn ? 1 : 0

  name           = "conexiones"
  log_group_name = aws_cloudwatch_log_group.client[0].name
}

resource "aws_ec2_client_vpn_endpoint" "this" {
  count = var.enable_client_vpn ? 1 : 0

  description            = "Acceso del equipo a la red privada de CONGENIA"
  server_certificate_arn = var.server_certificate_arn
  client_cidr_block      = var.client_cidr
  split_tunnel           = true

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = var.client_root_certificate_arn
  }

  connection_log_options {
    enabled               = true
    cloudwatch_log_group  = aws_cloudwatch_log_group.client[0].name
    cloudwatch_log_stream = aws_cloudwatch_log_stream.client[0].name
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-client-vpn" })
}

resource "aws_ec2_client_vpn_network_association" "this" {
  for_each = var.enable_client_vpn ? toset(var.client_vpn_subnet_ids) : []

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this[0].id
  subnet_id              = each.value
}

# Sin esta regla el tunel levanta pero no deja pasar nada.
resource "aws_ec2_client_vpn_authorization_rule" "vpc" {
  count = var.enable_client_vpn ? 1 : 0

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this[0].id
  target_network_cidr    = var.vpc_cidr
  authorize_all_groups   = true
  description            = "Alcance a toda la VPC de CONGENIA"
}
