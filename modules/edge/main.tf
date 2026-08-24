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

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[local.default_route].arn
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "this" {
  for_each = local.rule_routes

  listener_arn = aws_lb_listener.http.arn
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
