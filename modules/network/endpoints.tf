# =============================================================================
# VPC endpoints: alcanzar servicios de AWS sin salir a internet.
#
# Reduce la superficie expuesta y la dependencia del NAT Gateway, que es la
# pieza de red que mas cuesta.
# =============================================================================

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.data.id,
  ]

  tags = merge(var.tags, { Name = "${var.name_prefix}-s3-endpoint" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.app[*].id
  security_group_ids  = [aws_security_group.app.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.value}-endpoint" })
}
