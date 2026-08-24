variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ministack_endpoint" {
  type    = string
  default = "http://localhost:4566"
}

variable "name_prefix" {
  type    = string
  default = "congenia"
}

# ── Puente contenedor -> host ───────────────────────────────────────────────
# MiniStack publica el puerto del contenedor en el host y mapea
# host.docker.internal dentro de cada tarea ECS. Es el mecanismo con el que
# los servicios se encuentran entre si en local (en AWS real: Cloud Map).
variable "host_bridge" {
  type    = string
  default = "host.docker.internal"
}

# ── Imagenes ────────────────────────────────────────────────────────────────
variable "image_api" {
  type    = string
  default = "xavierlopez25/congenia:api-latest"
}

variable "image_frontend" {
  type    = string
  default = "xavierlopez25/congenia:frontend-latest"
}

variable "image_pdf_worker" {
  type    = string
  default = "xavierlopez25/congenia:pdf-worker-latest"
}

variable "image_keycloak" {
  type    = string
  default = "quay.io/keycloak/keycloak:26.6.1"
}

variable "image_rabbitmq" {
  type    = string
  default = "rabbitmq:3.13-management-alpine"
}

# ── Credenciales (SOLO LOCAL) ───────────────────────────────────────────────
# En AWS real estos valores viven en Secrets Manager, nunca en tfvars.
variable "postgres_password" {
  type      = string
  default   = "congenia_local_pwd"
  sensitive = true
}

variable "keycloak_admin_password" {
  type      = string
  default   = "admin"
  sensitive = true
}

variable "rabbitmq_user" {
  type    = string
  default = "congenia"
}

variable "rabbitmq_password" {
  type      = string
  default   = "congenia"
  sensitive = true
}

variable "app_encryption_key" {
  description = "64 hex chars (32 bytes)."
  type        = string
  default     = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  sensitive   = true
}
