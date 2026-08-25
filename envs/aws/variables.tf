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

variable "ephemeral" {
  description = <<-DESC
    Permite bajar el entorno completo con `terraform destroy`: el bucket de
    documentos se borra con su contenido y sus versiones, y los repos ECR con
    sus imagenes.

    Va en true porque esta cuenta es hoy un entorno de prueba que se levanta
    para demos y se destruye despues (~$0.25/hora). El dia que guarde datos que
    importen hay que ponerla en false; los modulos la traen apagada por
    defecto, asi que solo se enciende donde se declara.
  DESC
  type        = bool
  default     = true
}

# ── TLS ─────────────────────────────────────────────────────────────────────

variable "domain_name" {
  description = <<-DESC
    Dominio del punto de entrada publico. Registrado en name.com: los CNAME de
    validacion se crean a mano (ver certificate.tf). null = sin certificado,
    el ALB se queda con el listener 80.
  DESC
  type        = string
  default     = "congenia.app"
}

variable "subject_alternative_names" {
  description = <<-DESC
    Nombres adicionales del certificado. Agregar "*.congenia.app" no cuesta un
    registro de validacion extra: ACM reutiliza el mismo CNAME del apex.
  DESC
  type        = list(string)
  default     = []
}

variable "validate_certificate" {
  description = <<-DESC
    Segundo paso del proceso de TLS: espera a que ACM emita el certificado y
    entonces crea el listener 443. Encenderlo ANTES de crear el CNAME en
    name.com deja el apply esperando hasta 60 minutos.
  DESC
  type        = bool
  default     = false
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
