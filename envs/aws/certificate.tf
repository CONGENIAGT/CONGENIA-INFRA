# =============================================================================
# Certificado TLS del punto de entrada publico.
#
# Con `manage_dns = true` (el default) los nameservers de cogenia.app estan
# delegados a Route 53 y todo el proceso ocurre en un solo `apply`: Terraform
# crea el certificado, escribe los registros de validacion, espera el ISSUED y
# levanta el listener 443. No hay pasos manuales.
#
# `manage_dns = false` conserva el proceso anterior, para un dominio cuyo DNS
# viva fuera de la cuenta. Ahi la validacion sigue siendo de dos aplicaciones:
#
#   1. `make apply ENV=aws` -> crea el certificado en PENDING_VALIDATION.
#      `terraform output acm_validation_records` imprime el CNAME a crear.
#   2. Crear ese CNAME en el proveedor DNS. ACM lo detecta en minutos.
#   3. `TF_VAR_validate_certificate=true make apply ENV=aws` -> espera el
#      ISSUED y levanta el listener 443.
#
# Se separan a proposito: si `aws_acm_certificate_validation` se creara desde
# el primer apply sin que exista el registro, el apply quedaria colgado hasta
# 60 minutos esperando un DNS que nadie escribio.
# =============================================================================

locals {
  # Se calcula desde las variables, no desde el ARN del certificado, para que
  # el plan muestre las URLs finales en lugar de "known after apply".
  #
  # Con DNS administrado no hace falta `validate_certificate`: los registros
  # los crea este mismo apply, asi que esperar el ISSUED ya no puede colgarse
  # por un paso humano pendiente.
  gestiona_dns = var.domain_name != null && var.manage_dns
  tls_activo   = var.domain_name != null && (var.manage_dns || var.validate_certificate)
}

resource "aws_acm_certificate" "this" {
  count = var.domain_name == null ? 0 : 1

  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.tags, { Name = var.domain_name })
}

# La zona la crea envs/shared. Leerla como data source hace que este stack
# falle en `plan` con un mensaje claro si el bootstrap de DNS no se hizo.
data "aws_route53_zone" "public" {
  count = local.gestiona_dns ? 1 : 0

  name         = var.domain_name
  private_zone = false
}

module "dns" {
  count  = local.gestiona_dns ? 1 : 0
  source = "../../modules/dns"

  zone_id                   = data.aws_route53_zone.public[0].zone_id
  domain_validation_options = aws_acm_certificate.this[0].domain_validation_options
}

# Con DNS administrado se le pasan los FQDN de validacion, y el recurso espera
# exactamente a esos registros. Sin el, se limita a sondear el estado del
# certificado a la espera de un registro creado a mano.
resource "aws_acm_certificate_validation" "this" {
  count = local.tls_activo ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = local.gestiona_dns ? module.dns[0].validation_record_fqdns : null

  timeouts {
    create = "60m"
  }
}

# El ALIAS del dominio publico hacia el ALB.
#
# Va aqui y no dentro de modules/dns porque depende del ALB, mientras que la
# validacion del certificado tiene que ocurrir ANTES de que el ALB tenga su
# listener HTTPS. Declararlos juntos cerraria el ciclo
# edge -> validation -> dns -> edge.
#
# Es el registro que hacia obligatorio el paso manual en cada reconstruccion:
# el hostname del ALB cambia cada vez que se recrea la infraestructura.
resource "aws_route53_record" "public" {
  count = local.gestiona_dns ? 1 : 0

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = var.domain_name
  type    = "A"

  # ALIAS y no CNAME: el apex de un dominio no admite CNAME, y el ALIAS de
  # Route 53 no cobra por consulta.
  alias {
    name                   = module.edge.alb_dns_name
    zone_id                = module.edge.alb_zone_id
    evaluate_target_health = true
  }
}
