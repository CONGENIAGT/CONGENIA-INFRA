locals {
  name = "${var.connection.name_prefix}-${var.connection.environment}-db-access"
}

data "aws_partition" "current" {}

data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "relay" {
  name        = local.name
  description = "Tunel SSM a PostgreSQL; sin entrada ni SSH"
  vpc_id      = var.connection.vpc_id
  tags        = merge(var.tags, { Name = local.name })
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.relay.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "SSM y actualizaciones HTTPS por NAT existente"
  tags              = merge(var.tags, { Name = local.name })
}

resource "aws_vpc_security_group_egress_rule" "postgres" {
  security_group_id            = aws_security_group.relay.id
  referenced_security_group_id = var.connection.data_sg_id
  ip_protocol                  = "tcp"
  from_port                    = var.connection.db_port
  to_port                      = var.connection.db_port
  description                  = "Solo PostgreSQL"
  tags                         = merge(var.tags, { Name = local.name })
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  security_group_id            = var.connection.data_sg_id
  referenced_security_group_id = aws_security_group.relay.id
  ip_protocol                  = "tcp"
  from_port                    = var.connection.db_port
  to_port                      = var.connection.db_port
  description                  = local.name
  tags                         = merge(var.tags, { Name = local.name })
}

resource "aws_iam_role" "relay" {
  name = local.name
  path = "/congenia/db-access/"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.relay.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "relay" {
  name = local.name
  path = "/congenia/db-access/"
  role = aws_iam_role.relay.name
  tags = var.tags
}

resource "aws_instance" "relay" {
  ami                         = nonsensitive(data.aws_ssm_parameter.ami.value)
  instance_type               = "t4g.micro"
  subnet_id                   = var.connection.subnet_id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.relay.id]
  iam_instance_profile        = aws_iam_instance_profile.relay.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(var.tags, { Name = "${local.name}-root" })
  }

  user_data = <<-SH
    #!/bin/bash
    set -eu
    systemctl enable --now amazon-ssm-agent
  SH

  # La AMI se renueva al recrear el acceso, no al publicar una AMI de Amazon.
  # Start/stop son operaciones EC2: no declarar aws_ec2_instance_state aqui.
  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [aws_iam_role_policy_attachment.ssm, aws_vpc_security_group_egress_rule.https]
  tags       = merge(var.tags, { Name = local.name })
}

resource "aws_ssm_document" "tunnel" {
  name            = local.name
  document_type   = "Session"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Acceso exclusivo a RDS CONGENIA"
    sessionType   = "Port"
    parameters = {
      localPortNumber = {
        type           = "String"
        default        = "15432"
        allowedPattern = "^([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"
      }
    }
    properties = {
      host            = var.connection.db_host
      portNumber      = tostring(var.connection.db_port)
      localPortNumber = "{{ localPortNumber }}"
      type            = "LocalPortForwarding"
    }
  })
  tags = var.tags
}

# Las asignaciones opcionales tambien pertenecen a este stack.
# No concede credenciales PostgreSQL ni acceso al estado de infraestructura.
resource "aws_iam_policy" "operator" {
  name = "${local.name}-operator"
  path = "/congenia/db-access/"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["ssm:StartSession"]
        Resource  = [aws_instance.relay.arn, aws_ssm_document.tunnel.arn]
        Condition = { BoolIfExists = { "ssm:SessionDocumentAccessCheck" = "true" } }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = aws_instance.relay.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeVolumes", "ssm:DescribeInstanceInformation", "ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules", "ec2:DescribeSnapshots", "ec2:DescribeNetworkInterfaces", "iam:ListRoles", "iam:ListInstanceProfiles", "iam:ListPolicies", "ssm:ListDocuments"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:ResumeSession", "ssm:TerminateSession", "ssmmessages:OpenDataChannel"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.connection.region}:${var.connection.account_id}:session/$${aws:userid}-*"
      }
    ]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "operator" {
  for_each   = var.operator_role_names
  role       = each.value
  policy_arn = aws_iam_policy.operator.arn
}

resource "aws_iam_user_policy_attachment" "operator" {
  for_each   = var.operator_user_names
  user       = each.value
  policy_arn = aws_iam_policy.operator.arn
}
