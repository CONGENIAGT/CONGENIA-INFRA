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

    # RDS exige TLS (rds.force_ssl=1) y el Pool de src/config/db.js no declara
    # `ssl`, asi que node-postgres lee esta variable. `no-verify` cifra sin
    # validar la CA de Amazon, que Node no trae en su almacen por defecto.
    # Sin esto: "no pg_hba.conf entry ... no encryption".
    PGSSLMODE = "no-verify"
  }

  rabbit_env = {
    RABBITMQ_HOST     = "rabbitmq.${local.ns}"
    RABBITMQ_PORT     = tostring(local.ports.rabbitmq)
    RABBITMQ_VHOST    = "/"
    RABBITMQ_USER     = "congenia"
    RABBITMQ_PASSWORD = random_password.rabbitmq.result
  }

  s3_env = {
    S3_BUCKET = module.data.docs_bucket
    S3_REGION = var.region
  }
}

module "keycloak" {
  source = "../../modules/ecs-service"

  name             = "keycloak"
  name_prefix      = "${var.name_prefix}-${var.environment}"
  cpu_architecture = "X86_64"
  cluster_id       = module.platform.cluster_id
  image            = "quay.io/keycloak/keycloak:26.6.1"
  command          = ["start"]
  container_port   = local.ports.keycloak
  cpu              = "1024"
  memory           = "2048"

  environment = {
    KC_DB          = "postgres"
    KC_DB_URL      = "jdbc:postgresql://${module.data.db_address}:${module.data.db_port}/${module.data.db_name}?sslmode=require"
    KC_DB_USERNAME = "congenia"
    KC_DB_PASSWORD = data.aws_secretsmanager_secret_version.db.secret_string

    KC_BOOTSTRAP_ADMIN_USERNAME = "admin"
    KC_BOOTSTRAP_ADMIN_PASSWORD = random_password.keycloak_admin.result

    # `start` (modo produccion) exige TLS a menos que se le diga que hay un
    # proxy delante terminando la conexion. El ALB solo tiene listener 80,
    # asi que Keycloak habla HTTP y confia en las cabeceras X-Forwarded-*.
    # Sin esto: "Key material not provided to setup HTTPS" y exit 2.
    KC_HTTP_ENABLED    = "true"
    KC_PROXY_HEADERS   = "xforwarded"
    KC_HOSTNAME        = "http://${module.edge.alb_dns_name}"
    KC_HOSTNAME_STRICT = "false"
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

  name             = "rabbitmq"
  name_prefix      = "${var.name_prefix}-${var.environment}"
  cpu_architecture = "X86_64"
  cluster_id       = module.platform.cluster_id
  image            = "rabbitmq:3.13-management-alpine"
  container_port   = local.ports.rabbitmq
  extra_ports      = [15672]
  cpu              = "512"
  memory           = "1024"

  # El usuario `guest` que trae la imagen solo acepta conexiones desde
  # localhost, asi que hay que crear uno propio o ningun servicio se conecta.
  environment = {
    RABBITMQ_DEFAULT_USER  = "congenia"
    RABBITMQ_DEFAULT_PASS  = random_password.rabbitmq.result
    RABBITMQ_DEFAULT_VHOST = "/"
  }

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

  name             = "api"
  name_prefix      = "${var.name_prefix}-${var.environment}"
  cpu_architecture = "X86_64"
  cluster_id       = module.platform.cluster_id
  image            = "${local.registry}/congenia/api:${var.image_tag}"
  container_port   = local.ports.api
  cpu              = "1024"
  memory           = "2048"
  desired_count    = 2

  environment = merge(local.db_env, local.rabbit_env, local.s3_env, {
    NODE_ENV        = "production"
    PORT            = tostring(local.ports.api)
    OIDC_ISSUER_URL = "${local.keycloak_internal}/realms/congenia"
    OIDC_JWKS_URL   = "${local.keycloak_internal}/realms/congenia/protocol/openid-connect/certs"
    OIDC_AUDIENCE   = "congenia-api"
    # http, no https: el ALB solo tiene listener 80 (falta el certificado ACM
    # y el listener 443, punto 4 del checklist de PROPUESTA.md).
    FRONTEND_BASE_URL = "http://${module.edge.alb_dns_name}"
    CORS_ORIGINS      = "http://${module.edge.alb_dns_name}"
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

  name             = "pdf-worker"
  name_prefix      = "${var.name_prefix}-${var.environment}"
  cpu_architecture = "X86_64"
  cluster_id       = module.platform.cluster_id
  image            = "${local.registry}/congenia/pdf-worker:${var.image_tag}"
  cpu              = "1024"
  memory           = "2048"
  desired_count    = 2

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

  name             = "frontend"
  name_prefix      = "${var.name_prefix}-${var.environment}"
  cpu_architecture = "X86_64"
  cluster_id       = module.platform.cluster_id
  image            = "${local.registry}/congenia/frontend:${var.image_tag}"
  container_port   = local.ports.frontend
  cpu              = "512"
  memory           = "1024"

  subnet_ids             = module.network.app_subnet_ids
  security_group_ids     = [module.network.app_sg_id]
  execution_role_arn     = module.platform.execution_role_arn
  task_role_arn          = module.platform.task_role_arn
  log_group_name         = module.platform.log_group_names["frontend"]
  region                 = var.region
  attach_to_target_group = module.edge.target_group_arns["frontend"]
  tags                   = local.tags
}
