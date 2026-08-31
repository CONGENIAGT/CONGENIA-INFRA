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

variable "certificate_arn" {
  description = <<-DESC
    Certificado ACM ya emitido (ISSUED) para el listener 443. null = solo
    listener 80, que es lo que usa envs/local: MiniStack no emula TLS en el
    ALB. Cuando se pasa, el 80 deja de servir y redirige al 443.
  DESC
  type        = string
  default     = null
}

variable "ssl_policy" {
  description = "Politica TLS del listener 443. La de 2021 habilita TLS 1.3."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "tags" {
  type    = map(string)
  default = {}
}
