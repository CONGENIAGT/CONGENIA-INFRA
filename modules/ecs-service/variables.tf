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

variable "service_discovery_arn" {
  description = <<-DESC
    ARN de un servicio de Cloud Map para registrar la tarea en DNS privado.
    Se usa en AWS real para que los servicios se encuentren por nombre.
    En local queda en null: MiniStack no resuelve Cloud Map desde los
    contenedores y el wiring se hace por host.docker.internal.
  DESC
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
