terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket       = "congenia-tfstate"
    key          = "congenia/db-access/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = var.connection.region
  allowed_account_ids = [var.connection.account_id]
  default_tags {
    tags = local.tags
  }
}
