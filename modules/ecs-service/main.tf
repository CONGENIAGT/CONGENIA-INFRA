# =============================================================================
# Modulo: ecs-service
# Un servicio del docker-compose -> una task definition + un ECS service.
# Es el modulo que se reutiliza para los 6 contenedores de aplicacion.
# =============================================================================

locals {
  all_ports = concat(
    var.container_port > 0 ? [var.container_port] : [],
    var.extra_ports
  )

  container = merge(
    {
      name      = var.name
      image     = var.image
      essential = true

      portMappings = [
        for p in local.all_ports : {
          containerPort = p
          hostPort      = p
          protocol      = "tcp"
        }
      ]

      environment = [
        for k, v in var.environment : {
          name  = k
          value = v
        }
      ]

      secrets = [
        for k, v in var.secrets : {
          name      = k
          valueFrom = v
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    var.command == null ? {} : { command = var.command }
  )
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-${var.name}"
  requires_compatibilities = [var.launch_type]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([local.container])

  # Solo se emite cuando el entorno lo pide. Sin el bloque, Fargate asume
  # X86_64; en AWS real las imagenes son arm64 y hay que decirlo explicito.
  dynamic "runtime_platform" {
    for_each = var.cpu_architecture == null ? [] : [1]
    content {
      operating_system_family = "LINUX"
      cpu_architecture        = var.cpu_architecture
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${var.name}" })
}

resource "aws_ecs_service" "this" {
  name                              = "${var.name_prefix}-${var.name}"
  cluster                           = var.cluster_id
  task_definition                   = aws_ecs_task_definition.this.arn
  desired_count                     = var.desired_count
  launch_type                       = var.launch_type
  health_check_grace_period_seconds = var.attach_to_target_group == null ? 0 : var.health_check_grace_period_seconds

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  # Este bloque registra y da de baja las IPs de las tareas en el target group
  # automaticamente. No hace falta ningun paso posterior: la IP de la tarea no
  # se conoce en tiempo de plan, y es ECS quien la publica al arrancar.
  dynamic "load_balancer" {
    for_each = var.attach_to_target_group == null ? [] : [1]
    content {
      target_group_arn = var.attach_to_target_group
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  dynamic "service_registries" {
    for_each = var.service_discovery_arn == null ? [] : [1]
    content {
      registry_arn = var.service_discovery_arn
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${var.name}" })
}
