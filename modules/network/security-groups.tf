# =============================================================================
# Grupos de seguridad: una cadena estricta edge -> app -> data.
# db-access administra por separado una regla temporal a PostgreSQL.
# =============================================================================

resource "aws_security_group" "edge" {
  name        = "${var.name_prefix}-edge-sg"
  description = "ALB publico: unico punto de entrada desde internet"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP desde internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS desde internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Hacia la capa de aplicacion"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-edge-sg" })
}

locals {
  # Puertos que el ALB necesita en la capa app: los de sus tres target groups.
  app_ports_from_alb = {
    frontend = 80
    api      = 3000
    keycloak = 8080
  }

  # Trafico entre tareas de la capa app, por puerto. Antes era 0-65535 en ambos
  # sentidos: el ALB podia alcanzar RabbitMQ y su consola, y cualquier tarea
  # cualquier puerto de otra.
  app_ports_between_tasks = {
    "API interna (Cloud Map)"                         = 3000
    "RabbitMQ AMQP: API y worker"                     = 5672
    "Keycloak: JWKS para la API"                      = 8080
    "Consola de RabbitMQ: observacion de colas"       = 15672
    "Keycloak: cluster JGroups durante un despliegue" = 7800
    "Keycloak: deteccion de fallos de JGroups"        = 57800
  }
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "Tareas ECS: solo reciben del ALB o de sus pares"
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = local.app_ports_from_alb
    content {
      description     = "Desde el ALB: ${ingress.key}"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [aws_security_group.edge.id]
    }
  }

  dynamic "ingress" {
    for_each = local.app_ports_between_tasks
    content {
      description = ingress.key
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      self        = true
    }
  }

  ingress {
    description     = "Consola de Keycloak desde el relay de operadores (tunel SSM)"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.operator.id]
  }

  # Salida abierta: la API necesita NurseraAPI y el Agent necesita el LLM.
  # Un control de egreso por dominio queda como endurecimiento posterior.
  egress {
    description = "Salida a internet via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-sg" })
}

# Grupo que adjunta el relay de db-access para llegar a la consola de Keycloak.
# Vive aqui, y no en db-access, para que la regla de entrada al SG app sea
# inline como las demas: una regla agregada desde otro stack la borraria el
# siguiente apply de este. Sin el relay, el grupo no tiene miembros.
resource "aws_security_group" "operator" {
  name        = "${var.name_prefix}-operator-sg"
  description = "Relay de operadores: solo sale a la consola de Keycloak"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-operator-sg" })
}

resource "aws_vpc_security_group_egress_rule" "operator_keycloak" {
  security_group_id            = aws_security_group.operator.id
  referenced_security_group_id = aws_security_group.app.id
  description                  = "Keycloak 8080 en la capa app"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_security_group" "data" {
  name        = "${var.name_prefix}-data-sg"
  description = "Postgres / Redis: solo desde la capa de aplicacion"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-data-sg" })
}

# Antes del primer apply sobre una VPC existente, importar las tres reglas
# con scripts/migrate-data-sg-rules.sh. No usar ingress=[]: revocaria accesos.
resource "aws_vpc_security_group_ingress_rule" "data_postgres" {
  security_group_id            = aws_security_group.data.id
  referenced_security_group_id = aws_security_group.app.id
  description                  = "PostgreSQL desde la capa app"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "data_redis" {
  security_group_id            = aws_security_group.data.id
  referenced_security_group_id = aws_security_group.app.id
  description                  = "Redis desde la capa app"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_vpc_security_group_egress_rule" "data_vpc" {
  security_group_id = aws_security_group.data.id
  description       = "Solo dentro de la VPC"
  ip_protocol       = "-1"
  cidr_ipv4         = var.vpc_cidr
}
