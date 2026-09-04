variable "repositories" {
  description = "Repos ECR para las imagenes propias de CONGENIA."
  type        = list(string)
}

variable "immutable_image_tags" {
  description = <<-DESC
    Impide sobrescribir un tag ya publicado en ECR. Obliga a que cada version
    tenga su propio tag, que es justo lo que se quiere en un registro
    compartido y lo que hace idempotente al pipeline: republicar el mismo
    commit es un no-op detectable, no una sobrescritura silenciosa.
  DESC
  type        = bool
  default     = true
}

variable "retained_images" {
  description = <<-DESC
    Imagenes que conserva la lifecycle policy por repositorio. Bajarlo demasiado
    puede expirar una imagen que una task definition todavia referencia: ECS
    fallaria al reintentar el pull. Subirlo solo cuesta almacenamiento.
  DESC
  type        = number
  default     = 20
}

variable "allow_destroy" {
  description = <<-DESC
    Permite destruir los repositorios ECR aunque tengan imagenes publicadas.
    Debe activarse solo durante un destroy confirmado (`make nuke`).
  DESC
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
