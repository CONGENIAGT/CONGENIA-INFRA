# =============================================================================
# Modulo: dns
#
# Registros de validacion del certificado ACM en Route 53.
#
# Existe desde que los nameservers de cogenia.app se delegaron a Route 53.
# Antes estos CNAME se creaban a mano en name.com, y como ACM los reemite al
# recrear el certificado, ese paso manual volvia en cada reconstruccion.
#
# Dos cosas que este modulo deliberadamente NO hace:
#
#   - No crea la zona alojada. Vive en envs/shared, porque borrarla haria que
#     Route 53 asigne nameservers nuevos y obligaria a repetir la delegacion en
#     el registrador.
#
#   - No crea el ALIAS del dominio hacia el ALB, aunque sea un registro DNS y
#     parezca que le corresponde. Ese registro depende del ALB, el listener
#     HTTPS del ALB depende de que el certificado este emitido, y la emision
#     depende de estos registros de validacion. Meterlo aqui cerraria el ciclo
#     edge -> validation -> dns -> edge y Terraform rechazaria el grafo. El
#     ALIAS se declara en el entorno, despues de la validacion.
# =============================================================================

locals {
  # ACM emite el MISMO registro de validacion para un dominio y su comodin
  # (cogenia.app y *.cogenia.app comparten CNAME). Iterando por dominio,
  # Terraform intentaria crear dos veces el mismo nombre y el apply fallaria
  # con un conflicto. Agrupar por nombre de registro deduplica.
  validation_records = {
    for option in var.domain_validation_options :
    option.resource_record_name => {
      type   = option.resource_record_type
      record = option.resource_record_value
    }...
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.validation_records

  zone_id = var.zone_id
  name    = each.key
  type    = each.value[0].type
  records = [each.value[0].record]

  # TTL corto: este registro solo se consulta durante la emision y la
  # renovacion del certificado.
  ttl = 60

  # Una renovacion de ACM puede reemitir el mismo nombre. Sin esto, un
  # certificado recreado choca con el registro que dejo el anterior.
  allow_overwrite = true
}
