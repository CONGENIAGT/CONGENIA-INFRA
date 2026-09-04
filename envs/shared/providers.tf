# =============================================================================
# Entorno compartido y persistente.
#
# Contiene lo que NO debe morir en el ciclo diario de destruir y reconstruir:
# el registro de imagenes, la identidad de GitHub Actions y la zona DNS.
#
# `make destroy ENV=aws` borra todo el gasto significativo (NAT, ALB, RDS,
# Redis, Fargate) y deja este stack en pie, de modo que volver a levantar el
# entorno no obliga a reconstruir cinco imagenes ni a re-delegar nameservers.
#
# Este stack cuesta menos de un dolar al mes: la zona alojada y unos centavos
# de almacenamiento en ECR. Solo `make nuke` lo destruye, y eso es un cierre
# de proyecto, no una operacion de rutina.
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Estado separado del de la aplicacion a proposito: es lo que permite
  # destruir uno sin tocar el otro.
  backend "s3" {
    bucket       = "congenia-tfstate"
    key          = "congenia/shared/terraform.tfstate"
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
      Stack     = "shared"
    }
  }
}
