variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "congenia"
}

variable "environment" {
  description = "Entorno oficial al que pertenecen los recursos."
  type        = string
  default     = "prod"
}

variable "free_plan_mode" {
  description = <<-DESC
    Impone limites preventivos compatibles con el perfil de bajo consumo de
    la cuenta AWS Free Plan. No convierte servicios medidos en gratuitos: su
    consumo se descuenta de los creditos disponibles.
  DESC
  type        = bool
  default     = true
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

variable "db_backup_retention_days" {
  description = <<-DESC
    Dias de backups automaticos de RDS. El perfil AWS Free Plan usa 1, el valor
    por defecto de la API/CLI y compatible con la restriccion de la cuenta.
    Aumentar solo despues de cambiar el plan de la cuenta y revisar el costo de
    almacenamiento de backups.
  DESC
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

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "enable_private_endpoints" {
  description = <<-DESC
    Crea endpoints privados de ECR, Logs y Secrets Manager. Se mantienen
    disponibles para endurecimiento futuro, pero el perfil Free Plan usa el
    NAT ya requerido por la aplicacion para evitar ocho cargos hora-AZ
    adicionales.
  DESC
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "Activa WAF y sus reglas administradas. Tiene costo fijo adicional."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Activa VPC Flow Logs hacia CloudWatch. Tiene costo por ingestion y almacenamiento."
  type        = bool
  default     = false
}

variable "image_tag" {
  description = <<-DESC
    Tag por defecto, para cuando `image_tags` no trae uno para ese servicio.
    Debe ser reemplazado por el manifiesto images.tfvars antes de aplicar.
  DESC
  type        = string
  default     = "pending-publication"
}

variable "image_tags" {
  description = <<-DESC
    Tag desplegado por servicio: { api = "1.0.0-9696cd8", frontend = ... }.

    Existe porque los servicios viven en repositorios distintos y avanzan
    a ritmos distintos: un solo tag compartido obliga a republicar todas las
    imagenes para mover una. El valor lo genera `scripts/release-plan.sh` del
    repo orquestador y se versiona en `envs/aws/images.tfvars`, de modo que el
    control de versiones registra que imagen exacta corre cada servicio.
  DESC
  type        = map(string)
  default     = {}
}

variable "allow_destroy" {
  description = <<-DESC
    Desactiva temporalmente las protecciones que impiden destruir RDS, el
    bucket versionado y los repos ECR con contenido. Debe permanecer false en
    operacion normal; `make destroy ENV=aws` lo activa con confirmacion
    explicita antes de ejecutar el destroy.
  DESC
  type        = bool
  default     = false
}

variable "enable_services" {
  description = <<-DESC
    Arranca las tareas ECS permanentes. Debe quedar false durante bootstrap,
    publicacion de imagenes, migracion y configuracion TLS; se habilita solo
    cuando el sistema oficial esta listo para recibir trafico.
  DESC
  type        = bool
  default     = false
}

variable "service_desired_counts" {
  description = "Cantidad de tareas por servicio cuando enable_services=true."
  type        = map(number)
  default = {
    keycloak   = 1
    rabbitmq   = 1
    api        = 1
    pdf-worker = 1
    frontend   = 1
  }

  validation {
    condition = alltrue([
      for count in values(var.service_desired_counts) :
      floor(count) == count && count >= 0
    ])
    error_message = "Todos los service_desired_counts deben ser enteros no negativos."
  }
}

# ── TLS ─────────────────────────────────────────────────────────────────────

variable "domain_name" {
  description = <<-DESC
    Dominio del punto de entrada publico. Registrado en name.com: los CNAME de
    validacion se crean a mano (ver certificate.tf). null = sin certificado,
    el ALB se queda con el listener 80.
  DESC
  type        = string
  default     = "cogenia.app"
}

variable "subject_alternative_names" {
  description = <<-DESC
    Nombres adicionales del certificado. Agregar "*.cogenia.app" no cuesta un
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
