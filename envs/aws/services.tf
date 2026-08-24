# =============================================================================
# Servicios de aplicacion en AWS real.
# En AWS los servicios se encuentran por DNS privado de Cloud Map, no por
# host.docker.internal.
# =============================================================================

locals {
  ns = aws_service_discovery_private_dns_namespace.this.name

  keycloak_internal = "http://keycloak.${local.ns}:${local.ports.keycloak}"

  db_env = {
    POSTGRES_HOST     = module.data.db_address
    POSTGRES_PORT     = tostring(module.data.db_port)
    POSTGRES_DB       = module.data.db_name
    POSTGRES_USER     = "congenia"
    POSTGRES_PASSWORD = data.aws_secretsmanager_secret_version.db.secret_string
  }

  rabbit_env = {
    RABBITMQ_HOST  = "rabbitmq.${local.ns}"
    RABBITMQ_PORT  = tostring(local.ports.rabbitmq)
    RABBITMQ_VHOST = "/"
  }

  s3_env = {
    S3_BUCKET = module.data.docs_bucket
    S3_REGION = var.region
  }
}

module "keycloak" {
  source = "../../modules/ecs-service"

  name           = "keycloak"
  name_prefix    = "${var.name_prefix}-${var.environment}"
  cluster_id     = module.platform.cluster_id
  image          = "quay.io/keycloak/keycloak:26.6.1"
  command        = ["start"]
  container_port = local.ports.keycloak
  cpu            = "1024"
  memory         = "2048"

  environment = {
    KC_DB       = "postgres"
    KC_DB_URL   = "jdbc:postgresql://${module.data.db_address}:${module.data.db_port}/${module.data.db_name}"
    KC_HOSTNAME = "https://${module.edge.alb_dns_name}"
  }

  subnet_ids             = module.network.app_subnet_ids
  security_group_ids     = [module.network.app_sg_id]
  execution_role_arn     = module.platform.execution_role_arn
  task_role_arn          = module.platform.task_role_arn
  log_group_name         = module.platform.log_group_names["keycloak"]
  region                 = var.region
  attach_to_target_group = module.edge.target_group_arns["keycloak"]
  service_discovery_arn  = aws_service_discovery_service.this["keycloak"].arn
  tags                   = local.tags
}

module "rabbitmq" {
  source = "../../modules/ecs-service"

  name           = "rabbitmq"
  name_prefix    = "${var.name_prefix}-${var.environment}"
  cluster_id     = module.platform.cluster_id
  image          = "rabbitmq:3.13-management-alpine"
  container_port = local.ports.rabbitmq
  extra_ports    = [15672]
  cpu            = "512"
  memory         = "1024"

  subnet_ids            = module.network.app_subnet_ids
  security_group_ids    = [module.network.app_sg_id]
  execution_role_arn    = module.platform.execution_role_arn
  task_role_arn         = module.platform.task_role_arn
  log_group_name        = module.platform.log_group_names["rabbitmq"]
  region                = var.region
  service_discovery_arn = aws_service_discovery_service.this["rabbitmq"].arn
  tags                  = local.tags
}

module "api" {
  source = "../../modules/ecs-service"

  name           = "api"
  name_prefix    = "${var.name_prefix}-${var.environment}"
  cluster_id     = module.platform.cluster_id
  image          = "${local.registry}/congenia/api:${var.image_tag}"
  container_port = local.ports.api
  cpu            = "1024"
  memory         = "2048"
  desired_count  = 2

  environment = merge(local.db_env, local.rabbit_env, local.s3_env, {
    NODE_ENV          = "production"
    PORT              = tostring(local.ports.api)
    OIDC_ISSUER_URL   = "${local.keycloak_internal}/realms/congenia"
    OIDC_JWKS_URL     = "${local.keycloak_internal}/realms/congenia/protocol/openid-connect/certs"
    OIDC_AUDIENCE     = "congenia-api"
    FRONTEND_BASE_URL = "https://${module.edge.alb_dns_name}"
    CORS_ORIGINS      = "https://${module.edge.alb_dns_name}"
  })

  subnet_ids             = module.network.app_subnet_ids
  security_group_ids     = [module.network.app_sg_id]
  execution_role_arn     = module.platform.execution_role_arn
  task_role_arn          = module.platform.task_role_arn
  log_group_name         = module.platform.log_group_names["api"]
  region                 = var.region
  attach_to_target_group = module.edge.target_group_arns["api"]
  service_discovery_arn  = aws_service_discovery_service.this["api"].arn
  tags                   = local.tags
}

module "pdf_worker" {
  source = "../../modules/ecs-service"

  name          = "pdf-worker"
  name_prefix   = "${var.name_prefix}-${var.environment}"
  cluster_id    = module.platform.cluster_id
  image         = "${local.registry}/congenia/pdf-worker:${var.image_tag}"
  cpu           = "1024"
  memory        = "2048"
  desired_count = 2

  environment = merge(local.db_env, local.rabbit_env, local.s3_env, {
    NODE_ENV            = "production"
    RABBITMQ_QUEUE_MAIN = "consent.pdf.generate"
    RABBITMQ_QUEUE_DLQ  = "consent.pdf.generate.dlq"
    WORKER_PREFETCH     = "3"
  })

  subnet_ids         = module.network.app_subnet_ids
  security_group_ids = [module.network.app_sg_id]
  execution_role_arn = module.platform.execution_role_arn
  task_role_arn      = module.platform.task_role_arn
  log_group_name     = module.platform.log_group_names["pdf-worker"]
  region             = var.region
  tags               = local.tags
}

module "frontend" {
  source = "../../modules/ecs-service"

  name           = "frontend"
  name_prefix    = "${var.name_prefix}-${var.environment}"
  cluster_id     = module.platform.cluster_id
  image          = "${local.registry}/congenia/frontend:${var.image_tag}"
  container_port = local.ports.frontend
  cpu            = "512"
  memory         = "1024"

  subnet_ids             = module.network.app_subnet_ids
  security_group_ids     = [module.network.app_sg_id]
  execution_role_arn     = module.platform.execution_role_arn
  task_role_arn          = module.platform.task_role_arn
  log_group_name         = module.platform.log_group_names["frontend"]
  region                 = var.region
  attach_to_target_group = module.edge.target_group_arns["frontend"]
  tags                   = local.tags
}
