# =============================================================================
# Servicios de aplicacion en AWS real.
# En AWS los servicios se encuentran por DNS privado de Cloud Map, no por
# host.docker.internal.
# =============================================================================

locals {
  ns = aws_service_discovery_private_dns_namespace.this.name

  keycloak_internal = "http://keycloak.${local.ns}:${local.ports.keycloak}"

  db_env = {
    POSTGRES_HOST = module.data.db_address
    POSTGRES_PORT = tostring(module.data.db_port)
    POSTGRES_DB   = module.data.db_name
    POSTGRES_USER = "congenia"

    # RDS exige TLS (rds.force_ssl=1) y el Pool de src/config/db.js no declara
    # `ssl`, asi que node-postgres lee esta variable. `no-verify` cifra sin
    # validar la CA de Amazon, que Node no trae en su almacen por defecto.
    # Sin esto: "no pg_hba.conf entry ... no encryption".
    PGSSLMODE = "no-verify"
  }

  rabbit_env = {
    RABBITMQ_HOST  = "rabbitmq.${local.ns}"
    RABBITMQ_PORT  = tostring(local.ports.rabbitmq)
    RABBITMQ_VHOST = "/"
    RABBITMQ_USER  = "congenia"
  }

  s3_env = {
    # Sin esta variable la aplicacion cae a su default `http://seaweedfs:8333`
    # (dist/config/env.js) y pdf-worker muere al arrancar con
    # `getaddrinfo ENOTFOUND seaweedfs`. Es lo que lo dejaba en 0/2 tareas.
    S3_ENDPOINT = "https://s3.${var.region}.amazonaws.com"

    # El server la exige para firmar URLs (getRequiredEnv en
    # upload.service.js). Contra S3 real el navegador llega al mismo host que
    # la aplicacion, asi que apunta al mismo endpoint.
    S3_PUBLIC_ENDPOINT = "https://s3.${var.region}.amazonaws.com"

    S3_BUCKET = module.data.docs_bucket
    S3_REGION = var.region

    # Virtual-hosted, que es lo recomendado contra S3 real. Se puede pasar
    # desde que los dos servicios leen la variable con un parseo booleano de
    # verdad: antes usaban `z.coerce.boolean()`, que convierte "false" en true.
    S3_FORCE_PATH_STYLE = "false"
    S3_UPLOAD_MAX_BYTES = tostring(10 * 1024 * 1024)

    # S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY siguen sin pasarse, y ahora eso
    # es lo correcto y no una limitacion: sin llaves, el SDK recorre su cadena
    # de credenciales y usa el rol IAM de la tarea, que ya tiene politica sobre
    # el bucket. Ponerlas volveria a dejar el rol de adorno.
  }

  redis_env = {
    REDIS_HOST = module.data.redis_address
    REDIS_PORT = tostring(module.data.redis_port)
    REDIS_TLS  = "true"
  }

  # Con TLS encendido el trafico entra por el dominio; mientras tanto, por el
  # nombre del ALB. Ver certificate.tf.
  public_url = local.tls_activo ? "https://${var.domain_name}" : "http://${module.edge.alb_dns_name}"
}

module "keycloak" {
  source = "../../modules/ecs-service"

  name             = "keycloak"
  name_prefix      = "${var.name_prefix}-${var.environment}"
  cpu_architecture = "X86_64"
  cluster_id       = module.platform.cluster_id
  image            = "${local.registry}/congenia/keycloak:${local.image_tag["keycloak"]}"
  command          = ["start", "--import-realm"]
  container_port   = local.ports.keycloak
  cpu              = "512"
  memory           = "1024"
  desired_count    = var.enable_services ? lookup(var.service_desired_counts, "keycloak", 1) : 0

  environment = {
    KC_DB                       = "postgres"
    KC_DB_URL                   = "jdbc:postgresql://${module.data.db_address}:${module.data.db_port}/${module.data.db_name}?sslmode=require"
    KC_DB_USERNAME              = "congenia"
    KC_DB_SCHEMA                = "keycloak"
    KC_BOOTSTRAP_ADMIN_USERNAME = "admin"

    # `start` (modo produccion) exige TLS a menos que se le diga que hay un
    # proxy delante terminando la conexion. Keycloak sigue hablando HTTP hacia
    # adentro incluso con el listener 443 puesto: quien termina TLS es el ALB,
    # y Keycloak se entera por las cabeceras X-Forwarded-*.
    # Sin esto: "Key material not provided to setup HTTPS" y exit 2.
    KC_HTTP_ENABLED    = "true"
    KC_PROXY_HEADERS   = "xforwarded"
    KC_HOSTNAME        = local.public_url
    KC_HOSTNAME_STRICT = "false"
  }

  secrets = {
    KC_DB_PASSWORD              = aws_secretsmanager_secret.db.arn
    KC_BOOTSTRAP_ADMIN_PASSWORD = aws_secretsmanager_secret.keycloak_admin.arn
    KEYCLOAK_SADC_CLIENT_SECRET = aws_secretsmanager_secret.keycloak_sadc.arn
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
  cpu              = "256"
  memory           = "512"
  desired_count    = var.enable_services ? lookup(var.service_desired_counts, "rabbitmq", 1) : 0

  # El usuario `guest` que trae la imagen solo acepta conexiones desde
  # localhost, asi que hay que crear uno propio o ningun servicio se conecta.
  environment = {
    RABBITMQ_DEFAULT_USER  = "congenia"
    RABBITMQ_DEFAULT_VHOST = "/"
  }

  secrets = {
    RABBITMQ_DEFAULT_PASS = aws_secretsmanager_secret.rabbitmq.arn
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
  image            = "${local.registry}/congenia/api:${local.image_tag["api"]}"
  container_port   = local.ports.api
  cpu              = "512"
  memory           = "1024"
  desired_count    = var.enable_services ? lookup(var.service_desired_counts, "api", 1) : 0

  environment = merge(local.db_env, local.rabbit_env, local.s3_env, local.redis_env, {
    NODE_ENV               = "production"
    APP_ENV                = var.environment
    PORT                   = tostring(local.ports.api)
    OIDC_ISSUER_URL        = "${local.public_url}/realms/congenia"
    OIDC_JWKS_URL          = "${local.keycloak_internal}/realms/congenia/protocol/openid-connect/certs"
    OIDC_AUDIENCE          = "congenia-api"
    SESSION_EXPIRY_MINUTES = "60"

    FRONTEND_BASE_URL = local.public_url
    CORS_ORIGINS      = local.public_url
  })

  secrets = {
    POSTGRES_PASSWORD  = aws_secretsmanager_secret.db.arn
    RABBITMQ_PASSWORD  = aws_secretsmanager_secret.rabbitmq.arn
    APP_ENCRYPTION_KEY = aws_secretsmanager_secret.app_encryption_key.arn
    REDIS_PASSWORD     = aws_secretsmanager_secret.redis.arn
  }

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
  image            = "${local.registry}/congenia/pdf-worker:${local.image_tag["pdf-worker"]}"
  cpu              = "512"
  memory           = "1024"
  desired_count    = var.enable_services ? lookup(var.service_desired_counts, "pdf-worker", 1) : 0

  # Sin redis_env: el worker no tiene una sola referencia a Redis en su codigo
  # (src/config/env.ts ni siquiera declara la variable).
  environment = merge(local.db_env, local.rabbit_env, local.s3_env, {
    NODE_ENV            = "production"
    APP_ENV             = var.environment
    RABBITMQ_QUEUE_MAIN = "consent.pdf.generate"
    RABBITMQ_QUEUE_DLQ  = "consent.pdf.generate.dlq"
    WORKER_PREFETCH     = "3"

    # El bucket lo crea Terraform y el task role no tiene `s3:CreateBucket` a
    # proposito. Sin esto, un nombre de bucket equivocado terminaria en un
    # AccessDenied al intentar crearlo en vez de en un mensaje que se entienda.
    S3_AUTO_CREATE_BUCKET = "false"
  })

  secrets = {
    POSTGRES_PASSWORD = aws_secretsmanager_secret.db.arn
    RABBITMQ_PASSWORD = aws_secretsmanager_secret.rabbitmq.arn
  }

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
  image            = "${local.registry}/congenia/frontend:${local.image_tag["frontend"]}"
  container_port   = local.ports.frontend
  cpu              = "256"
  memory           = "512"
  desired_count    = var.enable_services ? lookup(var.service_desired_counts, "frontend", 1) : 0

  environment = {
    API_BASE_URL = ""
    APP_ENV      = var.environment
  }

  subnet_ids             = module.network.app_subnet_ids
  security_group_ids     = [module.network.app_sg_id]
  execution_role_arn     = module.platform.execution_role_arn
  task_role_arn          = module.platform.task_role_arn
  log_group_name         = module.platform.log_group_names["frontend"]
  region                 = var.region
  attach_to_target_group = module.edge.target_group_arns["frontend"]
  tags                   = local.tags
}
