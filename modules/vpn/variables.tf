variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "private_route_table_ids" {
  description = "Tablas de rutas que deben aprender las rutas del otro extremo."
  type        = list(string)
  default     = []
}

# ── Tunel hacia el dominio externo (DB de Nursera) ──────────────────────────
variable "enable_site_to_site" {
  description = <<-DESC
    Tunel IPsec hacia la red privada ajena donde vive la base de datos externa
    que necesita AnalyticsService.

    Requiere tres datos del otro dominio antes de encenderse: IP publica del
    gateway, ASN y rangos alcanzables.
  DESC
  type        = bool
  default     = false
}

variable "remote_gateway_ip" {
  description = "IP publica del gateway del otro dominio. Dato que ellos proveen."
  type        = string
  default     = null
}

variable "remote_bgp_asn" {
  type    = number
  default = 65000
}

variable "remote_cidrs" {
  description = "Rangos del otro dominio alcanzables por el tunel."
  type        = list(string)
  default     = []
}

# ── Acceso de operadores a la VPC ───────────────────────────────────────────
variable "enable_client_vpn" {
  description = <<-DESC
    VPN de cliente para que el equipo alcance recursos privados (RDS, consola
    de RabbitMQ, Keycloak) sin exponerlos en el ALB.

    Requiere emitir dos certificados en ACM (servidor y cliente). Es la
    alternativa a un bastion: no abre puertos de entrada, no hay host que
    parchear y cada conexion queda registrada.
  DESC
  type        = bool
  default     = false
}

variable "client_cidr" {
  description = "Rango que se reparte a los clientes VPN. No debe solapar con la VPC."
  type        = string
  default     = "10.100.0.0/22"
}

variable "server_certificate_arn" {
  description = "Certificado de servidor en ACM para el endpoint de Client VPN."
  type        = string
  default     = null
}

variable "client_root_certificate_arn" {
  description = "Certificado raiz de cliente en ACM (autenticacion mutua)."
  type        = string
  default     = null
}

variable "client_vpn_subnet_ids" {
  description = "Subredes donde se asocia el endpoint de Client VPN."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
