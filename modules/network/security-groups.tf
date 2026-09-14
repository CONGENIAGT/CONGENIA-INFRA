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

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "Tareas ECS: solo reciben del ALB o de sus pares"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Desde el ALB"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.edge.id]
  }

  ingress {
    description = "Entre servicios de la misma capa: API, Keycloak, Worker"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
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
