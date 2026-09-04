# =============================================================================
# NACLs: firewall SIN ESTADO a nivel de subred.
#
# Segunda linea de defensa por debajo de los security groups. La diferencia
# importa: un security group tiene estado (si permite la salida, la respuesta
# vuelve sola), una NACL no, y por eso hay que abrir explicitamente el rango
# efimero de vuelta. Es tambien el unico sitio donde se puede DENEGAR algo de
# forma explicita: un security group solo sabe permitir.
# =============================================================================

locals {
  ephemeral = { from = 1024, to = 65535 }

  nacl_tiers = var.enable_nacls ? {
    edge = var.edge_subnet_ids
    app  = var.app_subnet_ids
    data = var.data_subnet_ids
  } : {}

  # Pares (capa, subred) para las asociaciones.
  nacl_assoc = var.enable_nacls && var.associate_nacls ? merge([
    for tier, subnets in local.nacl_tiers : {
      for idx, subnet in subnets : "${tier}-${idx}" => {
        tier   = tier
        subnet = subnet
      }
    }
  ]...) : {}
}

resource "aws_network_acl" "this" {
  for_each = local.nacl_tiers

  vpc_id = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-${each.key}-nacl"
    Tier = each.key
  })
}

# La asociacion se separa del recurso principal a proposito: declarar
# `subnet_ids` dentro de `aws_network_acl` obliga a recrear la NACL entera cada
# vez que cambia el conjunto de subredes. Ver la variable `associate_nacls`.
resource "aws_network_acl_association" "this" {
  for_each = local.nacl_assoc

  network_acl_id = aws_network_acl.this[each.value.tier].id
  subnet_id      = each.value.subnet
}

# ── EDGE: expuesta a internet ───────────────────────────────────────────────

resource "aws_network_acl_rule" "edge_in_http" {
  count = var.enable_nacls ? 1 : 0

  network_acl_id = aws_network_acl.this["edge"].id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 80
  to_port        = 80
}

resource "aws_network_acl_rule" "edge_in_https" {
  count = var.enable_nacls ? 1 : 0

  network_acl_id = aws_network_acl.this["edge"].id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

# Respuestas de las conexiones que el propio ALB inicia hacia la capa app.
resource "aws_network_acl_rule" "edge_in_ephemeral" {
  count = var.enable_nacls ? 1 : 0

  network_acl_id = aws_network_acl.this["edge"].id
  rule_number    = 120
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = local.ephemeral.from
  to_port        = local.ephemeral.to
}

resource "aws_network_acl_rule" "edge_out" {
  count = var.enable_nacls ? 1 : 0

  network_acl_id = aws_network_acl.this["edge"].id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}

# ── APP: privada, alcanzable solo desde dentro de la VPC ────────────────────

resource "aws_network_acl_rule" "app_in_vpc" {
  count = var.enable_nacls ? 1 : 0

  network_acl_id = aws_network_acl.this["app"].id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 0
  to_port        = 0
}

# Respuestas de las llamadas salientes que hace la aplicacion via NAT.
resource "aws_network_acl_rule" "app_in_ephemeral" {
  count = var.enable_nacls ? 1 : 0

  network_acl_id = aws_network_acl.this["app"].id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = local.ephemeral.from
  to_port        = local.ephemeral.to
}

resource "aws_network_acl_rule" "app_out" {
  count = var.enable_nacls ? 1 : 0

  network_acl_id = aws_network_acl.this["app"].id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}

# ── DATA: sellada. Solo Postgres y Redis, solo dentro de la VPC ─────────────

resource "aws_network_acl_rule" "data_in_postgres" {
  count = var.enable_nacls ? 1 : 0

  network_acl_id = aws_network_acl.this["data"].id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 5432
  to_port        = 5432
}

resource "aws_network_acl_rule" "data_in_redis" {
  count = var.enable_nacls ? 1 : 0

  network_acl_id = aws_network_acl.this["data"].id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 6379
  to_port        = 6379
}

# Salida limitada a la VPC: la capa de datos no habla con internet ni aunque
# el enrutamiento cambiara por error.
resource "aws_network_acl_rule" "data_out_vpc" {
  count = var.enable_nacls ? 1 : 0

  network_acl_id = aws_network_acl.this["data"].id
  rule_number    = 100
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = local.ephemeral.from
  to_port        = local.ephemeral.to
}
