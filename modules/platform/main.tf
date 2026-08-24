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

  name                 = each.value
  image_tag_mutability = "MUTABLE"

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

# Rol que asume el codigo de la aplicacion (acceso a S3 y Secrets).
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = var.tags
}
