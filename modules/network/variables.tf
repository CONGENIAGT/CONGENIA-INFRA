variable "name_prefix" {
  description = "Prefijo aplicado a todos los recursos de red."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR de la VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Zonas de disponibilidad a usar."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "enable_nat_gateway" {
  description = "Crea NAT Gateway para salida controlada de las subredes privadas."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags comunes."
  type        = map(string)
  default     = {}
}

variable "enable_s3_endpoint" {
  description = <<-DESC
    Endpoint de tipo gateway hacia S3. El trafico de imagenes y PDFs deja de
    salir por el NAT Gateway: no toca internet y no se paga por GB.
  DESC
  type        = bool
  default     = true
}

variable "interface_endpoints" {
  description = <<-DESC
    Endpoints de tipo interface (ECR, CloudWatch Logs, Secrets Manager). Con
    ellos las tareas privadas alcanzan la API de AWS sin ruta a internet.
    Lista vacia = ninguno.
  DESC
  type        = list(string)
  default     = []
}
