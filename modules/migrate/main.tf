# =============================================================================
# Modulo: migrate
# Carga del esquema y los catalogos en RDS.
#
# En local, docker-compose monta CONGENIA-M1-SERVER/db/init en
# /docker-entrypoint-initdb.d y Postgres corre los .sql al crear el contenedor.
# RDS no tiene ese mecanismo: nace vacio y el esquema no lo pone nadie.
#
# El modulo declara SOLO la task definition. Ejecutarla es un paso imperativo
# explicito (`make migrate`) y no parte del `apply`: Terraform no tiene un
# recurso para "corre esto una vez", y resolverlo con un `null_resource` +
# `local-exec` meteria logica imperativa dentro del estado y obligaria a tener
# el AWS CLI en cualquiera que aplique. Ver PROPUESTA.md §8b.1.
# =============================================================================

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "migrate"
    image     = var.image
    essential = true

    environment = [
      { name = "PGHOST", value = var.db_host },
      { name = "PGPORT", value = tostring(var.db_port) },
      { name = "PGDATABASE", value = var.db_name },
      { name = "PGUSER", value = var.db_username },

      # RDS aplica rds.force_ssl=1. `require` cifra sin validar la CA de
      # Amazon, que la imagen oficial de Postgres no trae en su almacen.
      { name = "PGSSLMODE", value = "require" },

      # El esquema no es idempotente (23 CREATE TABLE sin IF NOT EXISTS), asi
      # que el entrypoint se salta la carga si las tablas ya existen. Poner
      # esta variable en "1" fuerza el intento igual.
      { name = "MIGRATE_FORCE", value = var.force ? "1" : "0" },
    ]

    # El password va por `secrets`, no por `environment`: como variable de
    # entorno quedaria en claro en `describe-task-definition` para cualquiera
    # con permiso de lectura sobre ECS. Exige que el execution role tenga
    # `secretsmanager:GetSecretValue` sobre este ARN (modules/platform).
    secrets = [
      { name = "PGPASSWORD", valueFrom = var.db_password_secret_arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.log_group_name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  dynamic "runtime_platform" {
    for_each = var.cpu_architecture == null ? [] : [1]
    content {
      operating_system_family = "LINUX"
      cpu_architecture        = var.cpu_architecture
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-migrate" })
}
