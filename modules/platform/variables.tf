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

variable "tags" {
  type    = map(string)
  default = {}
}
