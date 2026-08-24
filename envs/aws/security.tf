# =============================================================================
# Endurecimiento en AWS real.
#
# Aqui SI van en true los interruptores que en local quedaron apagados por
# limites del emulador. Es la diferencia entre los dos entornos, y esta
# concentrada en este archivo.
# =============================================================================

module "security" {
  source = "../../modules/security"

  name_prefix = "${var.name_prefix}-${var.environment}"
  vpc_id      = module.network.vpc_id
  vpc_cidr    = module.network.vpc_cidr

  enable_waf     = true
  alb_arn        = module.edge.alb_arn
  waf_rate_limit = 2000

  enable_flow_logs        = true
  flow_log_retention_days = 30

  # En AWS el filtro association.subnet-id funciona, asi que las NACL si se
  # asocian a sus subredes.
  enable_nacls    = true
  associate_nacls = true

  edge_subnet_ids = module.network.edge_subnet_ids
  app_subnet_ids  = module.network.app_subnet_ids
  data_subnet_ids = module.network.data_subnet_ids

  tags = local.tags
}

module "vpn" {
  source = "../../modules/vpn"

  name_prefix             = "${var.name_prefix}-${var.environment}"
  vpc_id                  = module.network.vpc_id
  vpc_cidr                = module.network.vpc_cidr
  private_route_table_ids = module.network.private_route_table_ids

  # Tunel al dominio externo: se enciende cuando tengamos los datos del otro
  # extremo. Es lo que desbloquea a AnalyticsService.
  enable_site_to_site = var.enable_site_to_site_vpn
  remote_gateway_ip   = var.remote_gateway_ip
  remote_cidrs        = var.remote_cidrs

  # Acceso de operadores a RDS, RabbitMQ y Keycloak sin publicarlos.
  enable_client_vpn           = var.enable_client_vpn
  server_certificate_arn      = var.client_vpn_server_certificate_arn
  client_root_certificate_arn = var.client_vpn_root_certificate_arn
  client_vpn_subnet_ids       = module.network.app_subnet_ids

  tags = local.tags
}
