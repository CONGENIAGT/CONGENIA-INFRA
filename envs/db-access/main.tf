variable "connection" {
  description = "Generado desde terraform output db_access_context; no contiene secretos."
  type = object({
    version     = number
    account_id  = string
    region      = string
    name_prefix = string
    environment = string
    vpc_id      = string
    subnet_id   = string
    data_sg_id  = string
    db_host     = string
    db_port     = number
    db_name     = string
  })
  validation {
    condition     = var.connection.version == 1 && var.connection.db_port == 5432 && can(regex("^[0-9]{12}$", var.connection.account_id))
    error_message = "Contrato db_access_context incompatible: requiere version=1, cuenta AWS y PostgreSQL 5432."
  }
}

locals {
  tags = {
    Project     = "CONGENIA"
    Environment = var.connection.environment
    Component   = "db-access"
    Stack       = "db-access"
    ManagedBy   = "terraform"
  }
}

variable "operator_role_names" {
  description = "Roles IAM existentes autorizados a operar el tunel. Sus asignaciones se eliminan con el acceso."
  type        = set(string)
  default     = []
}

variable "operator_user_names" {
  description = "Usuarios IAM existentes autorizados a operar el tunel. No son usuarios Keycloak."
  type        = set(string)
  default     = []
}

module "db_access" {
  source              = "../../modules/db-access"
  connection          = var.connection
  tags                = local.tags
  operator_role_names = var.operator_role_names
  operator_user_names = var.operator_user_names
}

output "access" {
  value = module.db_access.access
}
