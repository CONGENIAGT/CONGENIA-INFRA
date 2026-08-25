variable "name_prefix" {
  type = string
}

variable "ecr_repositories" {
  description = "Repos ECR para las imagenes propias de CONGENIA."
  type        = list(string)
  default     = ["congenia/api", "congenia/frontend", "congenia/pdf-worker"]
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
    de lectura/escritura acotados a ese bucket. null = sin politica (es lo que
    usa envs/local, donde las llaves estaticas de MiniStack ya sirven).
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

variable "ephemeral" {
  description = <<-DESC
    Permite destruir los repositorios ECR aunque tengan imagenes publicadas.
    Solo para entornos de prueba.
  DESC
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
