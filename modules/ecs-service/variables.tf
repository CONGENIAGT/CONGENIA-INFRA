variable "name" {
  description = "Nombre logico del servicio (api, keycloak, rabbitmq, ...)."
  type        = string
}

variable "name_prefix" {
  type = string
}

variable "cluster_id" {
  type = string
}

variable "image" {
  type = string
}

variable "cpu" {
  type    = string
  default = "256"
}

variable "memory" {
  type    = string
  default = "512"
}

variable "container_port" {
  description = "Puerto que expone el contenedor. 0 = servicio sin puerto (worker)."
  type        = number
  default     = 0
}

variable "extra_ports" {
  description = "Puertos adicionales (ej. consola de RabbitMQ)."
  type        = list(number)
  default     = []
}

variable "command" {
  type    = list(string)
  default = null
}

variable "environment" {
  type    = map(string)
  default = {}
}

variable "secrets" {
  description = "Mapa nombre de variable -> ARN de Secrets Manager para el contenedor."
  type        = map(string)
  default     = {}
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "log_group_name" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "attach_to_target_group" {
  description = "ARN del target group del ALB, o null si el servicio no se expone."
  type        = string
  default     = null
}

variable "health_check_grace_period_seconds" {
  description = "Tiempo que ECS ignora health checks fallidos mientras arranca una tarea asociada al ALB."
  type        = number
  default     = 0
}

variable "launch_type" {
  description = <<-DESC
    FARGATE  -> sin servidores que administrar, se paga por tarea.
    EC2      -> las tareas corren sobre instancias del cluster; es la palanca
                de costo para AWS real (una sola VM sostiene todo el stack)
                sin cambiar ninguna definicion de servicio.
  DESC
  type        = string
  default     = "FARGATE"

  validation {
    condition     = contains(["FARGATE", "EC2"], var.launch_type)
    error_message = "launch_type debe ser FARGATE o EC2."
  }
}

variable "cpu_architecture" {
  description = <<-DESC
    Arquitectura de la tarea: ARM64 o X86_64. null = no se declara el bloque
    y Fargate asume X86_64 (comportamiento historico, es lo que usa local).
    En AWS real va ARM64: las imagenes se construyen en Apple Silicon y
    Fargate Graviton cuesta menos.
  DESC
  type        = string
  default     = null

  validation {
    condition     = var.cpu_architecture == null || contains(["ARM64", "X86_64"], coalesce(var.cpu_architecture, "ARM64"))
    error_message = "cpu_architecture debe ser ARM64, X86_64 o null."
  }
}

variable "service_discovery_arn" {
  description = <<-DESC
    ARN de un servicio de Cloud Map para registrar la tarea en DNS privado,
    de modo que los servicios se encuentren por nombre y no por IP. null en
    los que nadie necesita resolver (frontend y pdf-worker).
  DESC
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
