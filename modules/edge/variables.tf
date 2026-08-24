variable "name_prefix" {
  type = string
}

variable "edge_subnet_ids" {
  type = list(string)
}

variable "edge_sg_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "routes" {
  description = <<-DESC
    Reglas de enrutamiento del ALB. Cada entrada crea un target group y una
    regla de listener. `paths` vacio marca el destino por defecto.
  DESC
  type = map(object({
    port         = number
    paths        = list(string)
    priority     = number
    health_check = optional(string, "/")
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
