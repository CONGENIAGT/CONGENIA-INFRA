# =============================================================================
# Certificado TLS del punto de entrada publico.
#
# El dominio (cogenia.app) esta registrado en name.com, no en Route 53, asi
# que Terraform no puede crear los registros de validacion: hay que pegarlos a
# mano en el panel del registrador. Por eso el proceso es de dos aplicaciones:
#
#   1. `make apply ENV=aws`  -> crea el certificado en PENDING_VALIDATION.
#      `terraform output acm_validation_records` imprime el CNAME a crear.
#   2. Crear ese CNAME en name.com. ACM lo detecta en minutos.
#   3. `TF_VAR_validate_certificate=true make apply ENV=aws` -> espera a que
#      el certificado quede ISSUED, levanta el listener 443, manda el 80 a
#      redirigir y cambia las URLs publicas a https.
#
# Se separa en dos pasos a proposito: si `aws_acm_certificate_validation` se
# creara desde el primer apply, el apply quedaria colgado hasta 60 minutos
# esperando un registro DNS que todavia no existe.
#
# Si algun dia se delegan los nameservers de cogenia.app a Route 53, esto se
# simplifica: los registros de validacion y el ALIAS al ALB los crearia
# Terraform y el paso manual desaparece.
# =============================================================================

locals {
  # Se calcula desde las variables, no desde el ARN del certificado, para que
  # el plan muestre las URLs finales en lugar de "known after apply".
  tls_activo = var.domain_name != null && var.validate_certificate
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

# No lleva `validation_record_fqdns`: los registros no los crea Terraform. El
# recurso se limita a esperar a que ACM emita el certificado.
resource "aws_acm_certificate_validation" "this" {
  count = local.tls_activo ? 1 : 0

  certificate_arn = aws_acm_certificate.this[0].arn

  timeouts {
    create = "60m"
  }
}
