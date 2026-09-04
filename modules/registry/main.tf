# =============================================================================
# Modulo: registry
#
# Repositorios ECR de las imagenes propias de CONGENIA. Vive en un stack con
# estado propio (envs/shared) y no en el de la aplicacion, porque las imagenes
# deben sobrevivir a `make destroy ENV=aws`: reconstruir el entorno no deberia
# obligar a republicar cinco imagenes que no cambiaron.
# =============================================================================

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name = each.value

  # IMMUTABLE impide que un `docker push` reescriba un tag ya publicado: dos
  # personas trabajando a la vez no pueden pisarse, y lo que se desplego con un
  # tag es para siempre ese contenido. El precio es que `latest` deja de tener
  # sentido, y por eso los tags se derivan del commit de cada repo.
  image_tag_mutability = var.immutable_image_tags ? "IMMUTABLE" : "MUTABLE"

  # Una imagen publicada como indice OCI deja manifiestos hijos sin etiqueta al
  # borrar el indice, y esos siguen bloqueando el borrado del repositorio.
  # `force_delete` evita tener que iterar a mano antes de cada destroy.
  force_delete = var.allow_destroy

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.tags, { Name = each.value })
}

# Con un pipeline que publica en cada merge, el almacenamiento crece sin techo:
# antes se publicaba a mano y el limite lo ponia la paciencia del operador.
#
# La regla borra las imagenes mas viejas mas alla de `retained_images`. El
# numero no es cosmetico: ECS referencia la imagen por tag, y expirar una que
# una task definition todavia usa haria fallar el proximo arranque de esa
# tarea. Por eso el default es holgado frente al ritmo de despliegue real.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Conservar las ultimas ${var.retained_images} imagenes"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.retained_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
