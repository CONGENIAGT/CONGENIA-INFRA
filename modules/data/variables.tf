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

variable "redis_version" {
  type    = string
  default = "7.1"
}

variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "docs_bucket_name" {
  description = "Bucket de imagenes y PDFs (reemplaza a SeaweedFS)."
  type        = string
}

variable "ephemeral" {
  description = <<-DESC
    Permite destruir el bucket de documentos aunque tenga contenido (incluidas
    las versiones). Solo para entornos de prueba: en produccion la proteccion
    por defecto evita borrar datos por accidente.
  DESC
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
