# =============================================================================
# CIE-10 monthly batch
#
# One-shot ECS task triggered by EventBridge Scheduler. The dashboard API stays
# in CONGENIA-M1-SERVER; this task only populates the CIE-10 queue tables.
# =============================================================================

locals {
  cie10_catalog_s3_uri       = coalesce(var.cie10_catalog_s3_uri, "s3://${module.data.docs_bucket}/cie10/input/CIE10.csv")
  cie10_translator_s3_uri    = coalesce(var.cie10_translator_s3_uri, "s3://${module.data.docs_bucket}/cie10/input/CIE10_Traductor.csv")
  cie10_review_export_s3_uri = coalesce(var.cie10_review_export_s3_prefix, "s3://${module.data.docs_bucket}/cie10/export/")
  cie10_optional_environment = var.cie10_max_records == null ? [] : [
    { name = "CIE10_MAX_RECORDS", value = tostring(var.cie10_max_records) },
  ]
}

resource "aws_ecs_task_definition" "cie10" {
  family                   = "${var.name_prefix}-${var.environment}-cie10"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = module.platform.execution_role_arn
  task_role_arn            = module.platform.task_role_arn

  container_definitions = jsonencode([{
    name      = "cie10"
    image     = "${local.registry}/congenia/cie10:${local.image_tag["cie10"]}"
    essential = true

    environment = concat([
      { name = "NODE_ENV", value = "production" },
      { name = "CIE10_SOURCE_MODE", value = "s3" },
      { name = "CIE10_CATALOG_S3_URI", value = local.cie10_catalog_s3_uri },
      { name = "CIE10_TRANSLATOR_S3_URI", value = local.cie10_translator_s3_uri },
      { name = "CIE10_REVIEW_EXPORT_S3_PREFIX", value = local.cie10_review_export_s3_uri },
      { name = "CIE10_OPENAI_MODEL", value = var.cie10_openai_model },
      { name = "CIE10_REASONING_EFFORT", value = var.cie10_reasoning_effort },
      { name = "POSTGRES_HOST", value = module.data.db_address },
      { name = "POSTGRES_PORT", value = tostring(module.data.db_port) },
      { name = "POSTGRES_DB", value = module.data.db_name },
      { name = "POSTGRES_USER", value = "congenia" },
      { name = "PGSSLMODE", value = "no-verify" },
    ], local.cie10_optional_environment)

    secrets = [
      { name = "POSTGRES_PASSWORD", valueFrom = aws_secretsmanager_secret.db.arn },
      { name = "OPENAI_API_KEY", valueFrom = aws_secretsmanager_secret.cie10_openai.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = module.platform.log_group_names["cie10"]
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-${var.environment}-cie10" })
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cie10_scheduler" {
  name               = "${var.name_prefix}-${var.environment}-cie10-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "cie10_scheduler" {
  statement {
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = [aws_ecs_task_definition.cie10.arn]
  }

  statement {
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      module.platform.execution_role_arn,
      module.platform.task_role_arn,
    ]
  }
}

resource "aws_iam_role_policy" "cie10_scheduler" {
  name   = "${var.name_prefix}-${var.environment}-cie10-scheduler"
  role   = aws_iam_role.cie10_scheduler.id
  policy = data.aws_iam_policy_document.cie10_scheduler.json
}

resource "aws_scheduler_schedule" "cie10_monthly" {
  name                         = "${var.name_prefix}-${var.environment}-cie10-monthly"
  description                  = "Monthly CONGENIA CIE-10 AI suggestion batch"
  schedule_expression          = var.cie10_monthly_schedule
  schedule_expression_timezone = "America/Guatemala"
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = module.platform.cluster_id
    role_arn = aws_iam_role.cie10_scheduler.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.cie10.arn
      launch_type         = "FARGATE"

      network_configuration {
        subnets          = module.network.app_subnet_ids
        security_groups  = [module.network.app_sg_id]
        assign_public_ip = false
      }
    }
  }
}
