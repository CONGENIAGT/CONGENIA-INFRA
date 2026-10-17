# =============================================================================
# CIE-10 monthly batch
#
# One-shot ECS task triggered by EventBridge Scheduler. The dashboard API stays
# in CONGENIA-M1-SERVER; this task only populates the CIE-10 queue tables.
# =============================================================================

locals {
  cie10_catalog_s3_uri       = coalesce(var.cie10_catalog_s3_uri, "s3://${module.data.docs_bucket}/cie10/input/CIE10.csv")
  cie10_translator_s3_uri    = coalesce(var.cie10_translator_s3_uri, "s3://${module.data.docs_bucket}/cie10/input/CIE10_Traductor.csv")
  cie10_reference_s3_uri     = coalesce(var.cie10_reference_s3_uri, "s3://${module.data.docs_bucket}/cie10/input/verasativa-cie-10.csv")
  cie10_review_export_s3_uri = coalesce(var.cie10_review_export_s3_prefix, "s3://${module.data.docs_bucket}/cie10/export/")
  cie10_optional_environment = var.cie10_max_records == null ? [] : [
    { name = "CIE10_MAX_RECORDS", value = tostring(var.cie10_max_records) },
  ]
  cie10_rag_environment = var.cie10_rag_version == null ? [] : [
    { name = "CIE10_RAG_VERSION", value = var.cie10_rag_version },
  ]
}

resource "aws_s3vectors_vector_bucket" "cie10" {
  vector_bucket_name = "${var.name_prefix}-${var.environment}-cie10-vectors"
  tags               = local.tags
}

resource "aws_s3vectors_index" "cie10" {
  vector_bucket_name = aws_s3vectors_vector_bucket.cie10.vector_bucket_name
  index_name         = "cie10-catalog"
  data_type          = "float32"
  dimension          = 512
  distance_metric    = "cosine"

  metadata_configuration {
    non_filterable_metadata_keys = [
      "codigo",
      "nombreInstitucional",
      "descripcionReferencia",
      "jerarquia",
      "source",
    ]
  }

  tags = local.tags
}

data "aws_iam_policy_document" "cie10_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cie10_batch" {
  name               = "${var.name_prefix}-${var.environment}-cie10-batch"
  assume_role_policy = data.aws_iam_policy_document.cie10_task_assume.json
  tags               = local.tags
}

resource "aws_iam_role" "cie10_indexer" {
  name               = "${var.name_prefix}-${var.environment}-cie10-indexer"
  assume_role_policy = data.aws_iam_policy_document.cie10_task_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "cie10_batch" {
  statement {
    actions = ["s3:GetObject", "s3:PutObject"]
    resources = [
      "arn:aws:s3:::${module.data.docs_bucket}/cie10/input/*",
      "arn:aws:s3:::${module.data.docs_bucket}/cie10/export/*",
    ]
  }
  statement {
    actions   = ["s3vectors:QueryVectors", "s3vectors:GetVectors"]
    resources = [aws_s3vectors_index.cie10.index_arn]
  }
}

resource "aws_iam_role_policy" "cie10_batch" {
  name   = "${var.name_prefix}-${var.environment}-cie10-batch"
  role   = aws_iam_role.cie10_batch.id
  policy = data.aws_iam_policy_document.cie10_batch.json
}

data "aws_iam_policy_document" "cie10_indexer" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${module.data.docs_bucket}/cie10/input/*"]
  }
  statement {
    actions   = ["s3vectors:PutVectors", "s3vectors:GetVectors", "s3vectors:QueryVectors"]
    resources = [aws_s3vectors_index.cie10.index_arn]
  }
}

resource "aws_iam_role_policy" "cie10_indexer" {
  name   = "${var.name_prefix}-${var.environment}-cie10-indexer"
  role   = aws_iam_role.cie10_indexer.id
  policy = data.aws_iam_policy_document.cie10_indexer.json
}

resource "aws_ecs_task_definition" "cie10" {
  family                   = "${var.name_prefix}-${var.environment}-cie10"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = module.platform.execution_role_arn
  task_role_arn            = aws_iam_role.cie10_batch.arn

  container_definitions = jsonencode([{
    name      = "cie10"
    image     = "${local.registry}/congenia/cie10:${local.image_tag["cie10"]}"
    essential = true

    environment = concat([
      { name = "NODE_ENV", value = "production" },
      { name = "CIE10_SOURCE_MODE", value = "s3" },
      { name = "CIE10_CATALOG_S3_URI", value = local.cie10_catalog_s3_uri },
      { name = "CIE10_TRANSLATOR_S3_URI", value = local.cie10_translator_s3_uri },
      { name = "CIE10_REFERENCE_CATALOG_S3_URI", value = local.cie10_reference_s3_uri },
      { name = "CIE10_REVIEW_EXPORT_S3_PREFIX", value = local.cie10_review_export_s3_uri },
      { name = "CIE10_VECTOR_BUCKET_NAME", value = aws_s3vectors_vector_bucket.cie10.vector_bucket_name },
      { name = "CIE10_VECTOR_INDEX_NAME", value = aws_s3vectors_index.cie10.index_name },
      { name = "CIE10_EMBEDDING_MODEL", value = "text-embedding-3-small" },
      { name = "CIE10_EMBEDDING_DIMENSIONS", value = "512" },
      { name = "CIE10_COMMAND", value = "batch" },
      { name = "CIE10_OPENAI_MODEL", value = var.cie10_openai_model },
      { name = "CIE10_REASONING_EFFORT", value = var.cie10_reasoning_effort },
      { name = "CIE10_REPAIR_ATTEMPTS", value = tostring(var.cie10_repair_attempts) },
      { name = "POSTGRES_HOST", value = module.data.db_address },
      { name = "POSTGRES_PORT", value = tostring(module.data.db_port) },
      { name = "POSTGRES_DB", value = module.data.db_name },
      { name = "POSTGRES_USER", value = "congenia_app" },
      { name = "PGSSLMODE", value = "no-verify" },
    ], local.cie10_optional_environment, local.cie10_rag_environment)

    secrets = [
      { name = "POSTGRES_PASSWORD", valueFrom = aws_secretsmanager_secret.db_app.arn },
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

resource "aws_ecs_task_definition" "cie10_indexer" {
  family                   = "${var.name_prefix}-${var.environment}-cie10-indexer"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = module.platform.execution_role_arn
  task_role_arn            = aws_iam_role.cie10_indexer.arn

  container_definitions = jsonencode([{
    name      = "cie10"
    image     = "${local.registry}/congenia/cie10:${local.image_tag["cie10"]}"
    essential = true
    environment = concat([
      { name = "NODE_ENV", value = "production" },
      { name = "CIE10_COMMAND", value = "index" },
      { name = "CIE10_SOURCE_MODE", value = "s3" },
      { name = "CIE10_CATALOG_S3_URI", value = local.cie10_catalog_s3_uri },
      { name = "CIE10_TRANSLATOR_S3_URI", value = local.cie10_translator_s3_uri },
      { name = "CIE10_REFERENCE_CATALOG_S3_URI", value = local.cie10_reference_s3_uri },
      { name = "CIE10_VECTOR_BUCKET_NAME", value = aws_s3vectors_vector_bucket.cie10.vector_bucket_name },
      { name = "CIE10_VECTOR_INDEX_NAME", value = aws_s3vectors_index.cie10.index_name },
      { name = "CIE10_EMBEDDING_MODEL", value = "text-embedding-3-small" },
      { name = "CIE10_EMBEDDING_DIMENSIONS", value = "512" },
      { name = "CIE10_OPENAI_MODEL", value = var.cie10_openai_model },
      { name = "CIE10_REASONING_EFFORT", value = var.cie10_reasoning_effort },
      { name = "POSTGRES_HOST", value = module.data.db_address },
      { name = "POSTGRES_PORT", value = tostring(module.data.db_port) },
      { name = "POSTGRES_DB", value = module.data.db_name },
      { name = "POSTGRES_USER", value = "congenia_app" },
      { name = "PGSSLMODE", value = "no-verify" },
    ], local.cie10_rag_environment)
    secrets = [
      { name = "POSTGRES_PASSWORD", valueFrom = aws_secretsmanager_secret.db_app.arn },
      { name = "OPENAI_API_KEY", valueFrom = aws_secretsmanager_secret.cie10_openai.arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = module.platform.log_group_names["cie10"]
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "indexer"
      }
    }
  }])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-${var.environment}-cie10-indexer" })
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
    effect  = "Allow"
    actions = ["ecs:RunTask"]
    # Todas las revisiones de esta unica familia, sin editar IAM por release.
    resources = ["arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task-definition/${var.name_prefix}-${var.environment}-cie10:*"]
  }

  statement {
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      module.platform.execution_role_arn,
      aws_iam_role.cie10_batch.arn,
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
  state                        = var.enable_cie10_schedule ? "ENABLED" : "DISABLED"

  depends_on = [aws_iam_role_policy.cie10_scheduler]

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
