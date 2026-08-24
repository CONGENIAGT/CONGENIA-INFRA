# =============================================================================
# Entorno AWS real.
#
# ESTADO: valida (`terraform validate`) pero NO se ha aplicado. Aplicarlo
# genera costo real. Ver PROPUESTA.md, seccion "Camino a AWS real".
#
# Sin bloque `endpoints`: esa es la unica diferencia estructural con
# envs/local. Los modulos son exactamente los mismos.
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Estado remoto compartido por el equipo. Crear el bucket y la tabla una
  # sola vez, fuera de este stack (bootstrap manual documentado en README).
  backend "s3" {
    bucket       = "congenia-tfstate"
    key          = "congenia/aws/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "CONGENIA"
      ManagedBy = "terraform"
    }
  }
}
