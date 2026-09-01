# =============================================================================
# CONGENIA - Stack local sobre MiniStack
#
# Traduccion 1:1 del docker-compose.yml del repo orquestador (CONGENIA-ORCH):
#
#   compose                 ->  aqui
#   ---------------------------------------------------------------
#   postgres                ->  RDS PostgreSQL           (contenedor real)
#   redis                   ->  ElastiCache Redis        (contenedor real)
#   seaweedfs               ->  S3                       (servicio nativo)
#   rabbitmq                ->  ECS service              (*)
#   keycloak                ->  ECS service
#   api (M1-SERVER)         ->  ECS service + ruta ALB
#   pdf_worker              ->  ECS service (sin puerto)
#   frontend (M1)           ->  ECS service + ruta ALB por defecto
#   -                       ->  ALB (sustituye al Nginx de la DMZ)
#
#   (*) Amazon MQ existe en MiniStack pero solo como plano de control: no
#       levanta broker real. RabbitMQ corre por tanto como tarea ECS.
#       MiniStack solo implementa el plano de control de Amazon MQ.
# =============================================================================

locals {
  tags = {
    Project     = "CONGENIA"
    Environment = "local"
    ManagedBy   = "terraform"
  }

  service_names = ["frontend", "api", "keycloak", "rabbitmq", "pdf-worker"]

  # Puertos internos de cada servicio (identicos a los del docker-compose).
  ports = {
    frontend = 80
    api      = 3000
    keycloak = 8080
    rabbitmq = 5672
  }
}

module "network" {
  source = "../../modules/network"

  name_prefix        = var.name_prefix
  vpc_cidr           = "10.0.0.0/16"
  azs                = ["${var.region}a", "${var.region}b"]
  enable_nat_gateway = true
  enable_s3_endpoint = true

  # Endpoints de interface: se prueban aqui para ver si MiniStack los soporta.
  interface_endpoints = ["ecr.api", "ecr.dkr", "logs", "secretsmanager"]

  tags = local.tags
}

module "data" {
  source = "../../modules/data"

  name_prefix      = var.name_prefix
  data_subnet_ids  = module.network.data_subnet_ids
  data_sg_id       = module.network.data_sg_id
  db_password      = var.postgres_password
  docs_bucket_name = "${var.name_prefix}-docs"
  docs_cors_allowed_origins = [
    "http://${module.edge.alb_dns_name}",
    "http://localhost:4566",
    "http://localhost:8080",
  ]
  multi_az      = false
  allow_destroy = true
  tags          = local.tags
}

module "platform" {
  source = "../../modules/platform"

  name_prefix   = var.name_prefix
  service_names = local.service_names
  allow_destroy = true
  tags          = local.tags
}

module "edge" {
  source = "../../modules/edge"

  name_prefix     = var.name_prefix
  vpc_id          = module.network.vpc_id
  edge_subnet_ids = module.network.edge_subnet_ids
  edge_sg_id      = module.network.edge_sg_id
  tags            = local.tags

  routes = {
    # Sin `paths` -> destino por defecto del listener.
    frontend = {
      port         = local.ports.frontend
      paths        = []
      priority     = 100
      health_check = "/"
    }
    api = {
      port         = local.ports.api
      paths        = ["/v1/*", "/api/*", "/health*", "/openapi.json", "/docs*"]
      priority     = 10
      health_check = "/health"
    }
    keycloak = {
      port         = local.ports.keycloak
      paths        = ["/realms/*", "/resources/*", "/admin/*"]
      priority     = 20
      health_check = "/"
    }
  }
}

# =============================================================================
# Wiring de la aplicacion
# =============================================================================

locals {
  # En AWS real: los endpoints de RDS/ElastiCache y los nombres Cloud Map.
  # En local: reconcile-alb.sh conecta las tareas a una red Docker auxiliar
  # con alias estables para los servicios ECS. Los servicios publicados por
  # MiniStack en el host siguen entrando por host.docker.internal.
  pg_host = module.data.db_address
  pg_port = module.data.db_port

  redis_url = "redis://${var.host_bridge}:${module.data.redis_port}"

  keycloak_internal = "http://keycloak:${local.ports.keycloak}"
  rabbit_host       = "rabbitmq"

  s3_endpoint        = "http://${var.host_bridge}:4566"
  s3_public_endpoint = "http://localhost:4566"

  db_env = {
    POSTGRES_HOST     = local.pg_host
    POSTGRES_PORT     = tostring(local.pg_port)
    POSTGRES_DB       = module.data.db_name
    POSTGRES_USER     = "congenia"
    POSTGRES_PASSWORD = var.postgres_password
  }

  rabbit_env = {
    RABBITMQ_HOST     = local.rabbit_host
    RABBITMQ_PORT     = tostring(local.ports.rabbitmq)
    RABBITMQ_USER     = var.rabbitmq_user
    RABBITMQ_PASSWORD = var.rabbitmq_password
    RABBITMQ_VHOST    = "/"
  }

  s3_env = {
    S3_ENDPOINT          = local.s3_endpoint
    S3_PUBLIC_ENDPOINT   = local.s3_public_endpoint
    S3_BUCKET            = module.data.docs_bucket
    S3_REGION            = var.region
    S3_ACCESS_KEY_ID     = "test"
    S3_SECRET_ACCESS_KEY = "test"
  }
}

# ── Identidad ───────────────────────────────────────────────────────────────
module "keycloak" {
  source = "../../modules/ecs-service"

  name           = "keycloak"
  name_prefix    = var.name_prefix
  cluster_id     = module.platform.cluster_id
  image          = var.image_keycloak
  command        = ["start-dev", "--import-realm"]
  container_port = local.ports.keycloak
  cpu            = "512"
  memory         = "1024"

  environment = {
    KC_BOOTSTRAP_ADMIN_USERNAME = "admin"
    KC_BOOTSTRAP_ADMIN_PASSWORD = var.keycloak_admin_password
    KEYCLOAK_SADC_CLIENT_SECRET = var.keycloak_sadc_client_secret
    KC_HTTP_ENABLED             = "true"
    KC_PROXY_HEADERS            = "xforwarded"
    KC_HOSTNAME                 = "http://${module.edge.alb_dns_name}"
    KC_HOSTNAME_STRICT          = "false"
  }

  subnet_ids             = module.network.app_subnet_ids
  security_group_ids     = [module.network.app_sg_id]
  execution_role_arn     = module.platform.execution_role_arn
  task_role_arn          = module.platform.task_role_arn
  log_group_name         = module.platform.log_group_names["keycloak"]
  region                 = var.region
  attach_to_target_group = module.edge.target_group_arns["keycloak"]
  tags                   = local.tags
}

# ── Mensajeria ──────────────────────────────────────────────────────────────
module "rabbitmq" {
  source = "../../modules/ecs-service"

  name           = "rabbitmq"
  name_prefix    = var.name_prefix
  cluster_id     = module.platform.cluster_id
  image          = var.image_rabbitmq
  container_port = local.ports.rabbitmq
  extra_ports    = [15672]
  cpu            = "256"
  memory         = "512"

  environment = {
    RABBITMQ_DEFAULT_USER  = var.rabbitmq_user
    RABBITMQ_DEFAULT_PASS  = var.rabbitmq_password
    RABBITMQ_DEFAULT_VHOST = "/"
  }

  subnet_ids         = module.network.app_subnet_ids
  security_group_ids = [module.network.app_sg_id]
  execution_role_arn = module.platform.execution_role_arn
  task_role_arn      = module.platform.task_role_arn
  log_group_name     = module.platform.log_group_names["rabbitmq"]
  region             = var.region
  tags               = local.tags
}

# ── API MedicalRecordManagement ─────────────────────────────────────────────
module "api" {
  source = "../../modules/ecs-service"

  name           = "api"
  name_prefix    = var.name_prefix
  cluster_id     = module.platform.cluster_id
  image          = var.image_api
  container_port = local.ports.api
  cpu            = "512"
  memory         = "1024"

  environment = merge(local.db_env, local.rabbit_env, local.s3_env, {
    NODE_ENV                  = "production"
    APP_ENV                   = "local"
    PORT                      = tostring(local.ports.api)
    APP_ENCRYPTION_KEY        = var.app_encryption_key
    REDIS_URL                 = local.redis_url
    AUTH_INTEGRATION_MODE     = "hybrid"
    OIDC_ISSUER_URL           = "http://${module.edge.alb_dns_name}/realms/congenia"
    OIDC_JWKS_URL             = "${local.keycloak_internal}/realms/congenia/protocol/openid-connect/certs"
    OIDC_AUDIENCE             = "congenia-api"
    SESSION_EXPIRY_MINUTES    = "60"
    FRONTEND_BASE_URL         = "http://${module.edge.alb_dns_name}"
    FRONTEND_FICHA_ROUTE      = "/"
    CORS_ORIGINS              = "http://${module.edge.alb_dns_name},http://localhost:4566"
    S3_PRESIGN_EXPIRY_SECONDS = "3600"
    S3_UPLOAD_MAX_BYTES       = "10485760"
  })

  subnet_ids             = module.network.app_subnet_ids
  security_group_ids     = [module.network.app_sg_id]
  execution_role_arn     = module.platform.execution_role_arn
  task_role_arn          = module.platform.task_role_arn
  log_group_name         = module.platform.log_group_names["api"]
  region                 = var.region
  attach_to_target_group = module.edge.target_group_arns["api"]
  tags                   = local.tags

  depends_on = [module.keycloak, module.rabbitmq]
}

# ── Worker asincrono de PDF ─────────────────────────────────────────────────
module "pdf_worker" {
  source = "../../modules/ecs-service"

  name        = "pdf-worker"
  name_prefix = var.name_prefix
  cluster_id  = module.platform.cluster_id
  image       = var.image_pdf_worker
  cpu         = "512"
  memory      = "1024"

  environment = merge(local.db_env, local.rabbit_env, local.s3_env, {
    NODE_ENV                        = "production"
    APP_ENV                         = "local"
    RABBITMQ_QUEUE_MAIN             = "consent.pdf.generate"
    RABBITMQ_QUEUE_DLQ              = "consent.pdf.generate.dlq"
    WORKER_PREFETCH                 = "3"
    WORKER_MAX_RETRIES              = "5"
    WORKER_RETRY_BACKOFF_MS         = "2000"
    WORKER_RETRY_BACKOFF_MULTIPLIER = "2"
  })

  subnet_ids         = module.network.app_subnet_ids
  security_group_ids = [module.network.app_sg_id]
  execution_role_arn = module.platform.execution_role_arn
  task_role_arn      = module.platform.task_role_arn
  log_group_name     = module.platform.log_group_names["pdf-worker"]
  region             = var.region
  tags               = local.tags

  depends_on = [module.rabbitmq]
}

# ── Frontend / ficha de registro ────────────────────────────────────────────
# La imagen resuelve API_BASE_URL al arrancar; una misma version sirve en ambos
# entornos sin hornear la URL de destino en el build.
module "frontend" {
  source = "../../modules/ecs-service"

  name           = "frontend"
  name_prefix    = var.name_prefix
  cluster_id     = module.platform.cluster_id
  image          = var.image_frontend
  container_port = local.ports.frontend
  cpu            = "256"
  memory         = "512"

  subnet_ids             = module.network.app_subnet_ids
  security_group_ids     = [module.network.app_sg_id]
  execution_role_arn     = module.platform.execution_role_arn
  task_role_arn          = module.platform.task_role_arn
  log_group_name         = module.platform.log_group_names["frontend"]
  region                 = var.region
  attach_to_target_group = module.edge.target_group_arns["frontend"]
  tags                   = local.tags
}
