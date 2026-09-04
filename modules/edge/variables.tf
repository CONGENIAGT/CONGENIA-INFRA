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

variable "enable_https" {
  description = <<-DESC
    Crea el listener 443 y convierte el 80 en redireccion.

    Va separada de `certificate_arn` porque decide un `count` y Terraform
    necesita resolverlo durante el plan: debe derivarse de la configuracion,
    no del ARN, que en un entorno nuevo no se conoce hasta el apply.
  DESC
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = <<-DESC
    Certificado ACM ya emitido (ISSUED) para el listener 443. Se espera el ARN
    que devuelve `aws_acm_certificate_validation`, no el del certificado: es lo
    que garantiza que el listener no se cree antes de la emision.
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
