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
# MiniStack publica RDS, Redis y su gateway en el host. Las tareas llegan a
# ellos mediante host.docker.internal; entre tareas ECS se usan alias Docker
# configurados por scripts/reconcile-alb.sh (en AWS real se usa Cloud Map).
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
  default = "congenia/keycloak:local"
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

variable "keycloak_sadc_client_secret" {
  type      = string
  default   = "congenia_local_sadc_secret"
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
