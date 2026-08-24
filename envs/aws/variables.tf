variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "congenia"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "multi_az" {
  description = "Multi-AZ en RDS. false en la primera iteracion por costo."
  type        = bool
  default     = false
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "image_tag" {
  description = "Tag desplegado. Lo publica el pipeline de cada repo de servicio."
  type        = string
  default     = "latest"
}

# ── Endurecimiento ──────────────────────────────────────────────────────────

variable "enable_site_to_site_vpn" {
  description = <<-DESC
    Tunel IPsec hacia el dominio externo (DB de Nursera). Requiere que el otro
    extremo provea IP publica del gateway, ASN y rangos alcanzables.
  DESC
  type        = bool
  default     = false
}

variable "remote_gateway_ip" {
  type    = string
  default = null
}

variable "remote_cidrs" {
  type    = list(string)
  default = []
}

variable "enable_client_vpn" {
  description = "Acceso del equipo a la red privada. Requiere certificados en ACM."
  type        = bool
  default     = false
}

variable "client_vpn_server_certificate_arn" {
  type    = string
  default = null
}

variable "client_vpn_root_certificate_arn" {
  type    = string
  default = null
}
