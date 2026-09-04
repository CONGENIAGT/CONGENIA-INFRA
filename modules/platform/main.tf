# =============================================================================
# Modulo: platform
# Plano de ejecucion compartido: cluster ECS, logs y roles.
#
# Los repositorios ECR ya no viven aqui: se movieron a envs/shared para que
# sobrevivan a `make destroy ENV=aws` (ver modules/registry).
# =============================================================================

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-cluster" })
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

# Acceso al bucket de documentos, acotado a ese bucket. En AWS la aplicacion no
# recibe llaves estaticas: el SDK usa la cadena de credenciales del task role.
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
