variable "name_prefix" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "service_names" {
  description = "Servicios que necesitan log group propio."
  type        = list(string)
}

variable "docs_bucket_name" {
  description = <<-DESC
    Nombre del bucket de documentos. Si se pasa, el task role recibe permisos
    de lectura/escritura acotados a ese bucket. null = sin politica.
    Se recibe como variable y no leyendo el modulo `data` para no encadenar los
    dos modulos: el cableado se hace en el entorno.
  DESC
  type        = string
  default     = null
}

variable "secret_arns" {
  description = <<-DESC
    Secretos que las tareas referencian con el bloque `secrets`. El execution
    role recibe `secretsmanager:GetSecretValue` solo sobre estos ARN.
  DESC
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
