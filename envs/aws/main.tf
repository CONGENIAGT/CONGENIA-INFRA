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

  service_names = ["frontend", "api", "keycloak", "rabbitmq", "pdf-worker"]

  ports = {
    frontend = 80
    api      = 3000
    keycloak = 8080
    rabbitmq = 5672
  }

  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
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
  docs_bucket_name  = "${var.name_prefix}-${var.environment}-docs"
  tags              = local.tags
}

module "platform" {
  source = "../../modules/platform"

  name_prefix   = "${var.name_prefix}-${var.environment}"
  service_names = local.service_names
  tags          = local.tags
}

module "edge" {
  source = "../../modules/edge"

  name_prefix     = "${var.name_prefix}-${var.environment}"
  vpc_id          = module.network.vpc_id
  edge_subnet_ids = module.network.edge_subnet_ids
  edge_sg_id      = module.network.edge_sg_id
  tags            = local.tags

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
