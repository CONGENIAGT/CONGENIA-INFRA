# =============================================================================
# Modulo: platform
# Plano de ejecucion compartido: cluster ECS, registro de imagenes, logs y roles.
# =============================================================================

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-cluster" })
}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.ecr_repositories)

  name = each.value

  # IMMUTABLE impide que un `docker push` reescriba un tag ya publicado: dos
  # personas trabajando a la vez no pueden pisarse, y lo que se desplego con un
  # tag es para siempre ese contenido. El precio es que `latest` deja de tener
  # sentido (solo se podria subir una vez), y por eso los tags se derivan del
  # commit de cada repo. En local se deja MUTABLE: MiniStack no lo emula y el
  # ciclo de prueba reconstruye la misma etiqueta todo el tiempo.
  image_tag_mutability = var.immutable_image_tags ? "IMMUTABLE" : "MUTABLE"

  # Una imagen publicada como indice OCI deja manifiestos hijos sin etiqueta al
  # borrar el indice, y esos siguen bloqueando el borrado del repositorio.
  # `force_delete` evita tener que iterar a mano antes de cada destroy.
  force_delete = var.ephemeral

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.tags, { Name = each.value })
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = toset(var.service_names)

  name              = "/ecs/${var.name_prefix}/${each.value}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, { Name = "/ecs/${var.name_prefix}/${each.value}" })
}

# ── Roles IAM ───────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Rol que usa el agente ECS para halar imagenes y escribir logs.
resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# `AmazonECSTaskExecutionRolePolicy` cubre ECR y CloudWatch Logs, pero NO
# incluye `secretsmanager:GetSecretValue`. Sin esta politica, cualquier tarea
# que declare un bloque `secrets` falla al arrancar con ResourceInitialization.
data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secret_arns) == 0 ? 0 : 1

  statement {
    sid       = "LeerSecretosDeLasTareas"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = length(var.secret_arns) == 0 ? 0 : 1

  name   = "${var.name_prefix}-execution-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# Rol que asume el codigo de la aplicacion (acceso a S3 y Secrets).
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = var.tags
}

# Acceso al bucket de documentos, acotado a ese bucket. Sustituye a las llaves
# estaticas que la aplicacion usa hoy contra SeaweedFS.
#
# OJO: la politica es condicion necesaria pero no suficiente. `src/lib/s3.ts`
# construye el S3Client pasando siempre `credentials`, asi que el SDK nunca
# consulta la cadena de credenciales del contenedor y el rol queda sin efecto.
# El cambio de codigo vive en los repos de aplicacion (PROPUESTA.md §9).
#
# Se recibe el NOMBRE del bucket y no su ARN a proposito: el ARN solo se conoce
# despues del apply, y `count` no admite valores desconocidos ("The count value
# depends on resource attributes that cannot be determined until apply"). El
# nombre, en cambio, es una cadena literal del entorno. Un ARN de S3 no lleva
# cuenta ni region, asi que derivarlo del nombre es exacto.
locals {
  docs_bucket_arn = var.docs_bucket_name == null ? null : "arn:aws:s3:::${var.docs_bucket_name}"
}

data "aws_iam_policy_document" "task_s3" {
  count = var.docs_bucket_name == null ? 0 : 1

  statement {
    sid    = "ObjetosDelBucketDeDocumentos"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = ["${local.docs_bucket_arn}/*"]
  }

  statement {
    sid       = "ListarSoloEseBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.docs_bucket_arn]
  }
}

resource "aws_iam_role_policy" "task_s3" {
  count = var.docs_bucket_name == null ? 0 : 1

  name   = "${var.name_prefix}-task-s3"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_s3[0].json
}
