# =============================================================================
# CONGENIA - Stack en AWS real
#
# Reutiliza los mismos modulos que envs/local. Las diferencias son:
#   - Las contrasenas salen de Secrets Manager, no de tfvars.
#   - Las imagenes salen de ECR, no de Docker Hub.
#   - Los servicios se encuentran por Cloud Map, no por host.docker.internal.
#   - No hace falta scripts/register-targets.sh: el registro es nativo.
# =============================================================================

data "aws_caller_identity" "current" {}

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
    for servicio in ["api", "frontend", "pdf-worker", "migrate"] :
    servicio => lookup(var.image_tags, servicio, var.image_tag)
  }
}

# ── Secretos ────────────────────────────────────────────────────────────────
# Se crean vacios por Terraform; los valores se cargan una vez, fuera del
# control de versiones (`aws secretsmanager put-secret-value`).

resource "aws_secretsmanager_secret" "db" {
  name = "${var.name_prefix}/${var.environment}/postgres"
  tags = local.tags

  # Sin ventana de recuperacion: de lo contrario `destroy` deja el nombre
  # reservado 30 dias y el siguiente `apply` falla al recrearlo.
  recovery_window_in_days = 0
}

data "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
}

# ── Credenciales internas ───────────────────────────────────────────────────
# A diferencia del password de Postgres (que se carga a mano porque el equipo
# lo necesita para conectarse), estas solo las consumen los contenedores. Las
# genera Terraform y quedan en Secrets Manager para poder auditarlas.

resource "random_password" "rabbitmq" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "rabbitmq" {
  name                    = "${var.name_prefix}/${var.environment}/rabbitmq"
  recovery_window_in_days = 0
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
  recovery_window_in_days = 0
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
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "keycloak_admin" {
  secret_id     = aws_secretsmanager_secret.keycloak_admin.id
  secret_string = random_password.keycloak_admin.result
}

module "network" {
  source = "../../modules/network"

  name_prefix        = "${var.name_prefix}-${var.environment}"
  vpc_cidr           = "10.0.0.0/16"
  azs                = ["${var.region}a", "${var.region}b"]
  enable_nat_gateway = true
  enable_s3_endpoint = true

  interface_endpoints = ["ecr.api", "ecr.dkr", "logs", "secretsmanager"]

  tags = local.tags
}

module "data" {
  source = "../../modules/data"

  name_prefix       = "${var.name_prefix}-${var.environment}"
  data_subnet_ids   = module.network.data_subnet_ids
  data_sg_id        = module.network.data_sg_id
  db_password       = data.aws_secretsmanager_secret_version.db.secret_string
  db_instance_class = var.db_instance_class
  redis_node_type   = var.redis_node_type
  multi_az          = var.multi_az
  docs_bucket_name  = local.docs_bucket_name
  ephemeral         = var.ephemeral
  tags              = local.tags
}

module "platform" {
  source = "../../modules/platform"

  name_prefix   = "${var.name_prefix}-${var.environment}"
  service_names = local.service_names

  # El repo de la imagen de migracion solo hace falta en AWS: en local el
  # esquema lo carga docker-entrypoint-initdb.d.
  ecr_repositories = [
    "congenia/api",
    "congenia/frontend",
    "congenia/pdf-worker",
    "congenia/migrate",
  ]

  # El nombre llega por variable y no leyendo el modulo `data` desde
  # `platform`, para no encadenar los dos modulos: el cableado vive aqui.
  docs_bucket_name = local.docs_bucket_name

  # Unico secreto que una tarea referencia con el bloque `secrets` (la de
  # migracion). Los demas se inyectan como environment desde Terraform.
  secret_arns = [aws_secretsmanager_secret.db.arn]

  immutable_image_tags = true
  ephemeral            = var.ephemeral
  tags                 = local.tags
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
      paths        = ["/v1/*", "/api/*", "/health"]
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
