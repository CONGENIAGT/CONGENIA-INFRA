locals {
  tags = {
    Project   = "CONGENIA"
    ManagedBy = "terraform"
    Stack     = "shared"
  }

  # Los mismos cinco repositorios que consume envs/aws. "migrate" no es un
  # servicio permanente, pero su imagen se publica y versiona igual que las
  # demas.
  ecr_repositories = [
    "congenia/api",
    "congenia/frontend",
    "congenia/pdf-worker",
    "congenia/keycloak",
    "congenia/migrate",
  ]
}

module "registry" {
  source = "../../modules/registry"

  repositories    = local.ecr_repositories
  retained_images = var.retained_images
  allow_destroy   = var.allow_destroy

  # Inmutable en AWS: es lo que hace que republicar el mismo commit sea un
  # no-op detectable en vez de una sobrescritura silenciosa.
  immutable_image_tags = true

  tags = local.tags
}

module "cicd" {
  source = "../../modules/cicd"

  name_prefix          = var.name_prefix
  ci_subjects          = var.ci_subjects
  ecr_repository_arns  = module.registry.repository_arns
  create_oidc_provider = var.create_oidc_provider

  tags = local.tags
}

# ── DNS ─────────────────────────────────────────────────────────────────────
# La zona vive aqui y no en envs/aws porque su borrado no es reversible sin
# intervencion manual: Route 53 asigna nameservers distintos a cada zona nueva,
# asi que recrearla obliga a volver al panel de name.com y esperar propagacion.
resource "aws_route53_zone" "public" {
  count = var.manage_dns ? 1 : 0

  name    = var.domain_name
  comment = "CONGENIA - delegada desde name.com"

  tags = merge(local.tags, { Name = var.domain_name })
}

data "aws_caller_identity" "current" {}

# Guarda local: falla durante el plan, antes de pedirle un solo recurso a AWS.
#
# Existe porque el paso 1.3 de docs/DEPLOY.md ofrece un bloque de variables
# para cuentas que no son la oficial, y copiarlo por error deja
# `TF_VAR_domain_name` con un dominio de ejemplo. El plan entonces propone una
# zona alojada perfectamente valida para un dominio que nadie controla: cuesta
# dinero, no resuelve nada, y el error solo se nota al intentar delegar.
resource "terraform_data" "dominio_guard" {
  input = var.domain_name

  lifecycle {
    precondition {
      condition = !var.manage_dns || !can(regex(
        "(?i)(ejemplo|example|cambiar|tu-dominio|midominio)", var.domain_name
      ))
      error_message = <<-ERROR
        `domain_name` parece un marcador de posicion: "${var.domain_name}".

        Si estas en la cuenta oficial, el valor correcto es el default y
        sobran las variables del bloque "cuenta que NO es la oficial":

          unset TF_CLI_ARGS_init TF_VAR_name_prefix TF_VAR_domain_name

        Si es una cuenta propia, poner un dominio real bajo tu control: la
        zona de Route 53 solo sirve si podes delegarle los nameservers.
      ERROR
    }
  }
}
