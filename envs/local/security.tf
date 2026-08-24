# =============================================================================
# Endurecimiento: perimetro, trazabilidad de red y acceso privado.
#
# Los interruptores en false NO son omisiones: son limites de MiniStack, cada
# uno verificado ejecutandolo. En envs/aws los mismos modulos van en true.
# =============================================================================

module "security" {
  source = "../../modules/security"

  name_prefix = var.name_prefix
  vpc_id      = module.network.vpc_id
  vpc_cidr    = module.network.vpc_cidr

  # WAF delante del ALB. Funciona en MiniStack: el WebACL se crea y se asocia.
  enable_waf     = true
  alb_arn        = module.edge.alb_arn
  waf_rate_limit = 2000

  # Flow logs de la VPC hacia CloudWatch. Funciona en MiniStack.
  enable_flow_logs        = true
  flow_log_retention_days = 14

  # Las NACL se crean con sus reglas, pero NO se asocian a las subredes:
  # DescribeNetworkAcls de MiniStack ignora el filtro association.subnet-id y
  # devuelve todas las NACL de la cuenta, con lo que el provider aborta.
  enable_nacls    = true
  associate_nacls = false

  edge_subnet_ids = module.network.edge_subnet_ids
  app_subnet_ids  = module.network.app_subnet_ids
  data_subnet_ids = module.network.data_subnet_ids

  tags = local.tags
}

module "vpn" {
  source = "../../modules/vpn"

  name_prefix             = var.name_prefix
  vpc_id                  = module.network.vpc_id
  vpc_cidr                = module.network.vpc_cidr
  private_route_table_ids = module.network.private_route_table_ids

  # Tunel al dominio externo: apagado. aws_vpn_connection se crea pero el
  # provider lee despues DescribeTransitGatewayAttachments, que MiniStack no
  # implementa, y aborta el apply.
  enable_site_to_site = false

  # Acceso de operadores: apagado. Client VPN no existe en MiniStack
  # (DescribeClientVpnEndpoints responde "Unknown EC2 action").
  enable_client_vpn = false

  tags = local.tags
}
