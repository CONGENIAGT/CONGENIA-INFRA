# =============================================================================
# Modulo: edge
# ALB como unico punto de entrada. Sustituye al proxy inverso Nginx que en el
# diseno original vivia en una EC2 de la DMZ: mismas reglas, sin servidor que
# parchear.
# =============================================================================

locals {
  # El destino por defecto es la ruta sin patrones de path (el frontend).
  default_route = one([for k, v in var.routes : k if length(v.paths) == 0])
  rule_routes   = { for k, v in var.routes : k => v if length(v.paths) > 0 }

  https_enabled = var.certificate_arn != null

  # Las reglas de path cuelgan del listener que sirve trafico. Con TLS ese es
  # el 443, porque el 80 pasa a redirigir y una regla ahi nunca se evaluaria.
  # `one()` sobre la lista evita indexar un recurso con count = 0: el operador
  # ternario de HCL evalua ambas ramas.
  serving_listener_arn = coalesce(
    one(aws_lb_listener.https[*].arn),
    aws_lb_listener.http.arn,
  )
}

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = var.edge_subnet_ids
  security_groups    = [var.edge_sg_id]

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_lb_target_group" "this" {
  for_each = var.routes

  name        = "${var.name_prefix}-${each.key}-tg"
  port        = each.value.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled  = true
    path     = each.value.health_check
    matcher  = "200-399"
    interval = 30
    timeout  = 5
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}-tg" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # Sin certificado el 80 sirve el trafico directamente. Con certificado, este
  # mismo listener pasa a redirigir al 443.
  dynamic "default_action" {
    for_each = local.https_enabled ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this[local.default_route].arn
    }
  }

  # Con certificado, el 80 deja de servir y solo empuja al 443.
  dynamic "default_action" {
    for_each = local.https_enabled ? [1] : []
    content {
      type = "redirect"

      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  tags = var.tags
}

# Solo existe cuando el entorno pasa un certificado ya emitido. El ALB rechaza
# un certificado en PENDING_VALIDATION, asi que el ARN debe venir del recurso
# aws_acm_certificate_validation y no del certificado directo.
resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[local.default_route].arn
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "this" {
  for_each = local.rule_routes

  listener_arn = local.serving_listener_arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  condition {
    path_pattern {
      values = each.value.paths
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}-rule" })
}
