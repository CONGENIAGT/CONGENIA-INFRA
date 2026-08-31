variable "name_prefix" {
  type = string
}

variable "image" {
  description = <<-DESC
    Imagen con los .sql horneados (`make migrate-image` la construye y la
    publica en ECR). Se prefiere hornearlos a descargarlos en tiempo de
    ejecucion: la version manual hacia `apk add curl`, lo que ataba la tarea
    al NAT Gateway y a que una URL siguiera viva.
  DESC
  type        = string
}

variable "db_host" {
  type = string
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "db_password_secret_arn" {
  description = "ARN del secreto de Secrets Manager con el password de Postgres."
  type        = string
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type    = string
  default = null
}

variable "log_group_name" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cpu" {
  type    = string
  default = "256"
}

variable "memory" {
  type    = string
  default = "512"
}

variable "cpu_architecture" {
  description = "ARM64 o X86_64. null = no se declara el bloque y Fargate asume X86_64."
  type        = string
  default     = null
}

variable "force" {
  description = <<-DESC
    Corre los .sql aunque el esquema ya exista. Solo tiene sentido contra una
    base que se pueda perder: los CREATE TABLE fallaran uno a uno.
  DESC
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
