variable "zone_id" {
  description = "Zona alojada publica, creada en envs/shared."
  type        = string
}

variable "domain_validation_options" {
  description = <<-DESC
    `domain_validation_options` del certificado ACM. Se recibe crudo para que
    el modulo no tenga que conocer como se declaro el certificado.
  DESC
  type        = any
}
