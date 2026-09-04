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
