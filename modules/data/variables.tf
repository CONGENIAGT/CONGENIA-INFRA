variable "name_prefix" {
  type = string
}

variable "data_subnet_ids" {
  type = list(string)
}

variable "data_sg_id" {
  type = string
}

variable "postgres_version" {
  type    = string
  default = "16"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_name" {
  type    = string
  default = "congenia"
}

variable "db_username" {
  type    = string
  default = "congenia"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "multi_az" {
  description = "Multi-AZ en RDS. false en local y en la primera iteracion por costo."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Dias de backups automaticos de RDS."
  type        = number
  default     = 1

  validation {
    condition = (
      floor(var.db_backup_retention_days) == var.db_backup_retention_days &&
      var.db_backup_retention_days >= 0 &&
      var.db_backup_retention_days <= 35
    )
    error_message = "db_backup_retention_days debe ser un numero entero entre 0 y 35."
  }
}

variable "db_deletion_protection" {
  description = "Impide borrar RDS hasta desactivar explicitamente la proteccion."
  type        = bool
  default     = false
}

variable "redis_version" {
  type    = string
  default = "7.1"
}

variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "redis_transit_encryption_enabled" {
  type    = bool
  default = false
}

variable "redis_at_rest_encryption_enabled" {
  type    = bool
  default = false
}

variable "redis_auth_token" {
  type      = string
  sensitive = true
  default   = null
}

variable "redis_snapshot_retention_days" {
  type    = number
  default = 0
}

variable "docs_bucket_name" {
  description = "Bucket de imagenes y PDFs (reemplaza a SeaweedFS)."
  type        = string
}

variable "docs_cors_allowed_origins" {
  description = "Origenes web exactos autorizados a hacer PUT con URL firmada."
  type        = list(string)
  default     = []
}

variable "allow_destroy" {
  description = <<-DESC
    Permite destruir el bucket aunque tenga contenido y omitir el snapshot
    final de RDS. Debe activarse solo durante un destroy confirmado.
  DESC
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
