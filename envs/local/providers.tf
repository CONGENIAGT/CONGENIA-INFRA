# =============================================================================
# Entorno LOCAL -> MiniStack (emulador AWS en http://localhost:4566)
#
# Nota sobre el .tf original de la PoC: declaraba un endpoint `vpc = ...`.
# Ese argumento no existe en el provider de AWS (las operaciones de VPC viajan
# por el endpoint `ec2`) y hace fallar `terraform validate`. Aqui esta corregido.
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region     = var.region
  access_key = "test"
  secret_key = "test"

  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2            = var.ministack_endpoint
    ecs            = var.ministack_endpoint
    ecr            = var.ministack_endpoint
    elbv2          = var.ministack_endpoint
    rds            = var.ministack_endpoint
    elasticache    = var.ministack_endpoint
    s3             = var.ministack_endpoint
    logs           = var.ministack_endpoint
    iam            = var.ministack_endpoint
    kms            = var.ministack_endpoint
    secretsmanager = var.ministack_endpoint
    sts            = var.ministack_endpoint
    route53        = var.ministack_endpoint
    cloudwatch     = var.ministack_endpoint
    wafv2          = var.ministack_endpoint
  }
}
