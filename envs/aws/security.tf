# =============================================================================
# Controles de seguridad del entorno AWS oficial.
#
# WAF y Flow Logs son configurables porque ambos consumen creditos incluso con
# menos de 1 TPS. Security groups y NACLs permanecen activos siempre.
# =============================================================================

module "security" {
  source = "../../modules/security"

  name_prefix = "${var.name_prefix}-${var.environment}"
  vpc_id      = module.network.vpc_id
  vpc_cidr    = module.network.vpc_cidr

  enable_waf     = var.enable_waf
  alb_arn        = module.edge.alb_arn
  waf_rate_limit = 2000

  # Dos reglas del conjunto comun quedan en conteo, no en bloqueo:
  # - SizeRestrictions_BODY bloquea cuerpos de mas de 8 KB, y el alta de la
  #   ficha lleva la firma PNG en base64 (la API acepta hasta 300 KB y valida
  #   el PNG por su cuenta).
  # - NoUserAgent_HEADER bloquea peticiones sin User-Agent, que algunos
  #   clientes servidor a servidor no envian (integracion SADC por OAuth).
  # El resto del conjunto, entradas maliciosas, SQLi y el limite por IP bloquean.
  waf_rule_action_overrides = {
    AWSManagedRulesCommonRuleSet = ["SizeRestrictions_BODY", "NoUserAgent_HEADER"]
  }

  enable_flow_logs        = var.enable_flow_logs
  flow_log_retention_days = 7

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
