variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

# ── Perimetro (WAF) ─────────────────────────────────────────────────────────
variable "enable_waf" {
  description = "WebACL de WAFv2 asociado al ALB."
  type        = bool
  default     = true
}

variable "alb_arn" {
  description = "ALB al que se asocia el WebACL. Obligatorio cuando enable_waf."
  type        = string
  default     = null
}

variable "waf_rate_limit" {
  description = "Peticiones por IP en 5 minutos antes de bloquear."
  type        = number
  default     = 2000
}

variable "waf_managed_rule_groups" {
  description = "Grupos de reglas administradas de AWS, en orden de prioridad."
  type        = list(string)
  default = [
    "AWSManagedRulesCommonRuleSet",
    "AWSManagedRulesKnownBadInputsRuleSet",
    "AWSManagedRulesSQLiRuleSet",
  ]
}

# ── Trazabilidad de red (Flow Logs) ─────────────────────────────────────────
variable "enable_flow_logs" {
  description = "Registra el trafico aceptado y rechazado de la VPC."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  type    = number
  default = 14
}

# ── Firewall sin estado (NACLs) ─────────────────────────────────────────────
variable "enable_nacls" {
  description = "Crea las listas de control de acceso por capa."
  type        = bool
  default     = true
}

variable "associate_nacls" {
  description = <<-DESC
    Asocia cada NACL a sus subredes. Debe quedar en false contra MiniStack:
    su DescribeNetworkAcls ignora el filtro `association.subnet-id` y devuelve
    todas las NACL de la cuenta, con lo que el provider aborta con
    "too many results: wanted 1". En AWS real va en true.
  DESC
  type        = bool
  default     = false
}

variable "edge_subnet_ids" {
  type    = list(string)
  default = []
}

variable "app_subnet_ids" {
  type    = list(string)
  default = []
}

variable "data_subnet_ids" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
