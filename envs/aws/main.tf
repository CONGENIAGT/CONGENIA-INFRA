# =============================================================================
# CONGENIA - Stack en AWS real
#
# Caracteristicas del entorno:
#   - Las contrasenas las genera Terraform y viven en Secrets Manager.
#   - Las imagenes salen de ECR, publicadas por el pipeline de cada repo.
#   - Los servicios se encuentran por Cloud Map, no por host.docker.internal.
#   - No hace falta scripts/register-targets.sh: el registro es nativo.
# =============================================================================

data "aws_caller_identity" "current" {}

# Los repositorios ECR los crea envs/shared, no este stack: deben sobrevivir a
# `make destroy ENV=aws`. Leerlos como data source en lugar de construir la URL
# a mano convierte "todavia no aplicaste envs/shared" en un error de `plan`
# claro, antes de pedirle un solo recurso a AWS.
data "aws_ecr_repository" "this" {
  for_each = toset([
    "congenia/api",
    "congenia/frontend",
    "congenia/pdf-worker",
    "congenia/keycloak",
    "congenia/migrate",
  ])

  name = each.value
}

locals {
  tags = {
    Project     = "CONGENIA"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # "migrate" no es un servicio permanente, pero necesita log group propio:
  # es la unica forma de leer lo que hizo la tarea despues de que termina.
  service_names = ["frontend", "api", "keycloak", "rabbitmq", "pdf-worker", "migrate"]

  ports = {
    frontend = 80
    api      = 3000
    keycloak = 8080
    rabbitmq = 5672
  }

  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  # Una sola fuente para el nombre: lo consume el modulo `data` al crear el
  # bucket y el modulo `platform` al acotar la politica del task role.
  docs_bucket_name = "${var.name_prefix}-${var.environment}-docs"

  # Tag de cada imagen, con el default como red de seguridad.
  image_tag = {
    for servicio in ["api", "frontend", "pdf-worker", "keycloak", "migrate"] :
    servicio => lookup(var.image_tags, servicio, var.image_tag)
  }
}

# Guardas locales: fallan durante plan, antes de solicitar recursos a AWS. El
# perfil puede relajarse explicitamente cuando cambie el plan de la cuenta.
resource "terraform_data" "free_plan_guard" {
  input = var.free_plan_mode

  lifecycle {
    precondition {
      condition     = !var.free_plan_mode || !var.multi_az
      error_message = "AWS Free Plan requiere multi_az=false en este stack."
    }

    precondition {
      condition     = !var.free_plan_mode || contains(["db.t3.micro", "db.t4g.micro"], var.db_instance_class)
      error_message = "AWS Free Plan requiere db.t3.micro o db.t4g.micro."
    }

    precondition {
      condition     = !var.free_plan_mode || contains(["cache.t3.micro", "cache.t4g.micro"], var.redis_node_type)
      error_message = "El perfil de bajo consumo requiere Redis cache.t3.micro o cache.t4g.micro."
    }

    precondition {
      condition     = !var.free_plan_mode || var.db_backup_retention_days <= 1
      error_message = "AWS Free Plan limita la retencion automatica de RDS a un dia en esta cuenta."
    }

    precondition {
      condition = !var.free_plan_mode || alltrue([
        for count in values(var.service_desired_counts) : count <= 1
      ])
      error_message = "El perfil menor a 1 TPS permite como maximo una tarea por servicio."
    }
  }
}

# ── Secretos ────────────────────────────────────────────────────────────────
# Los valores los genera Terraform y se guardan en Secrets Manager. El estado
# remoto cifrado es requisito porque los recursos `random_*` son sensibles.

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name = "${var.name_prefix}/${var.environment}/postgres"
  tags = local.tags

  # En operacion normal un borrado accidental deja 30 dias para restaurarlo.
  # El flujo automatizado de destroy elimina de inmediato solo tras confirmar.
  recovery_window_in_days = var.allow_destroy ? 0 : 30
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = random_password.db.result
}

# ── Credenciales internas ───────────────────────────────────────────────────
# Terraform genera todas estas credenciales; los operadores recuperan una solo
# cuando un procedimiento (por ejemplo el smoke OAuth) lo exige.

resource "random_password" "rabbitmq" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "rabbitmq" {
  name                    = "${var.name_prefix}/${var.environment}/rabbitmq"
  recovery_window_in_days = var.allow_destroy ? 0 : 30
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "rabbitmq" {
  secret_id     = aws_secretsmanager_secret.rabbitmq.id
  secret_string = random_password.rabbitmq.result
}

# La API valida que sean 64 caracteres hexadecimales
# (src/utils/sessionTokenCrypto.js). `random_id` con 32 bytes da exactamente
# eso; `random_password` daria alfanumerico y la API lo rechazaria.
resource "random_id" "app_encryption_key" {
  byte_length = 32
}

resource "aws_secretsmanager_secret" "app_encryption_key" {
  name                    = "${var.name_prefix}/${var.environment}/app-encryption-key"
  recovery_window_in_days = var.allow_destroy ? 0 : 30
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "app_encryption_key" {
  secret_id     = aws_secretsmanager_secret.app_encryption_key.id
  secret_string = random_id.app_encryption_key.hex
}

resource "random_password" "keycloak_admin" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "keycloak_admin" {
  name                    = "${var.name_prefix}/${var.environment}/keycloak-admin"
  recovery_window_in_days = var.allow_destroy ? 0 : 30
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "keycloak_admin" {
  secret_id     = aws_secretsmanager_secret.keycloak_admin.id
  secret_string = random_password.keycloak_admin.result
}

resource "random_password" "keycloak_sadc" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "keycloak_sadc" {
  name                    = "${var.name_prefix}/${var.environment}/keycloak-sadc-client"
  recovery_window_in_days = var.allow_destroy ? 0 : 30
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "keycloak_sadc" {
  secret_id     = aws_secretsmanager_secret.keycloak_sadc.id
  secret_string = random_password.keycloak_sadc.result
}

resource "random_password" "keycloak_medico_initial" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "keycloak_medico_initial" {
  name                    = "${var.name_prefix}/${var.environment}/keycloak-medico-initial"
  recovery_window_in_days = var.allow_destroy ? 0 : 30
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "keycloak_medico_initial" {
  secret_id     = aws_secretsmanager_secret.keycloak_medico_initial.id
  secret_string = random_password.keycloak_medico_initial.result
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "redis" {
  name                    = "${var.name_prefix}/${var.environment}/redis"
  recovery_window_in_days = var.allow_destroy ? 0 : 30
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "redis" {
  secret_id     = aws_secretsmanager_secret.redis.id
  secret_string = random_password.redis.result
}

module "network" {
  source = "../../modules/network"

  name_prefix        = "${var.name_prefix}-${var.environment}"
  vpc_cidr           = "10.0.0.0/16"
  azs                = ["${var.region}a", "${var.region}b"]
  enable_nat_gateway = true
  enable_s3_endpoint = true

  # El endpoint gateway de S3 no tiene costo adicional. Los endpoints de
  # interface se dejan opcionales porque el NAT ya cubre estas dependencias y
  # cada endpoint se factura por hora en cada AZ.
  interface_endpoints = var.enable_private_endpoints ? ["ecr.api", "ecr.dkr", "logs", "secretsmanager"] : []

  tags = local.tags
}

module "data" {
  source = "../../modules/data"

  name_prefix                      = "${var.name_prefix}-${var.environment}"
  data_subnet_ids                  = module.network.data_subnet_ids
  data_sg_id                       = module.network.data_sg_id
  db_password                      = random_password.db.result
  db_instance_class                = var.db_instance_class
  redis_node_type                  = var.redis_node_type
  multi_az                         = var.multi_az
  docs_bucket_name                 = local.docs_bucket_name
  docs_cors_allowed_origins        = [local.public_url]
  db_backup_retention_days         = var.db_backup_retention_days
  db_deletion_protection           = !var.allow_destroy
  redis_transit_encryption_enabled = true
  redis_at_rest_encryption_enabled = true
  redis_auth_token                 = random_password.redis.result
  redis_snapshot_retention_days    = 0
  allow_destroy                    = var.allow_destroy
  tags                             = local.tags
}

module "platform" {
  source = "../../modules/platform"

  name_prefix   = "${var.name_prefix}-${var.environment}"
  service_names = local.service_names

  # El nombre llega por variable y no leyendo el modulo `data` desde
  # `platform`, para no encadenar los dos modulos: el cableado vive aqui.
  docs_bucket_name = local.docs_bucket_name

  secret_arns = [
    aws_secretsmanager_secret.db.arn,
    aws_secretsmanager_secret.rabbitmq.arn,
    aws_secretsmanager_secret.app_encryption_key.arn,
    aws_secretsmanager_secret.keycloak_admin.arn,
    aws_secretsmanager_secret.keycloak_sadc.arn,
    aws_secretsmanager_secret.keycloak_medico_initial.arn,
    aws_secretsmanager_secret.redis.arn,
  ]

  tags = local.tags
}

module "edge" {
  source = "../../modules/edge"

  name_prefix     = "${var.name_prefix}-${var.environment}"
  vpc_id          = module.network.vpc_id
  edge_subnet_ids = module.network.edge_subnet_ids
  edge_sg_id      = module.network.edge_sg_id
  tags            = local.tags

  # null mientras el certificado no este emitido: `one()` sobre un recurso con
  # count = 0 devuelve null y el modulo se queda solo con el listener 80.
  certificate_arn = one(aws_acm_certificate_validation.this[*].certificate_arn)

  routes = {
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

# ── Descubrimiento de servicios ─────────────────────────────────────────────
resource "aws_service_discovery_private_dns_namespace" "this" {
  name = "${var.name_prefix}.internal"
  vpc  = module.network.vpc_id
  tags = local.tags
}

resource "aws_service_discovery_service" "this" {
  for_each = toset(["keycloak", "rabbitmq", "api"])

  name = each.value

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this.id

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  tags = local.tags
}

# ── Carga del esquema ───────────────────────────────────────────────────────
# Solo declara la task definition. Se ejecuta con `make migrate` (ENV=aws).
module "migrate" {
  source = "../../modules/migrate"

  name_prefix = "${var.name_prefix}-${var.environment}"
  image       = "${local.registry}/congenia/migrate:${local.image_tag["migrate"]}"

  db_host                = module.data.db_address
  db_port                = module.data.db_port
  db_name                = module.data.db_name
  db_username            = "congenia"
  db_password_secret_arn = aws_secretsmanager_secret.db.arn

  execution_role_arn = module.platform.execution_role_arn
  log_group_name     = module.platform.log_group_names["migrate"]
  region             = var.region
  cpu_architecture   = "X86_64"
  tags               = local.tags
}
