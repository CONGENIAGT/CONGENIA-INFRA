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
  # La clave es `domain_name` y no `resource_record_name` a proposito, aunque
  # agrupar por nombre de registro pareceria mas correcto para deduplicar.
  #
  # `for_each` exige conocer sus CLAVES durante el plan. De un certificado que
  # todavia no existe, ACM solo puede anticipar los dominios —salen de la
  # configuracion— pero no los nombres ni los valores de validacion, que asigna
  # al emitirlo. Keyear por el nombre del registro deja el mapa entero como
  # "known only after apply" y el plan falla antes de crear nada.
  #
  # Los valores si pueden ser desconocidos: por eso el nombre y el contenido
  # del registro viajan dentro del value.
  validation_records = {
    for option in var.domain_validation_options :
    option.domain_name => {
      name   = option.resource_record_name
      type   = option.resource_record_type
      record = option.resource_record_value
    }
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.validation_records

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]

  # TTL corto: este registro solo se consulta durante la emision y la
  # renovacion del certificado.
  ttl = 60

  # Necesario por dos motivos. Uno: una renovacion de ACM puede reemitir el
  # mismo nombre, y sin esto un certificado recreado choca con el registro que
  # dejo el anterior. Dos: un dominio y su comodin (`cogenia.app` y
  # `*.cogenia.app`) comparten el MISMO registro de validacion, asi que al
  # iterar por dominio se generan dos instancias que escriben lo mismo.
  allow_overwrite = true
}
