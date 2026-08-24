# =============================================================================
# WAF: filtrado de capa 7 delante del ALB.
#
# Es el firewall que faltaba en el perimetro. Los security groups deciden
# quien puede abrir una conexion; el WAF decide que peticiones pasan una vez
# abierta. Son controles distintos y hacen falta los dos.
# =============================================================================

resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0

  name        = "${var.name_prefix}-waf"
  description = "Perimetro de CONGENIA: OWASP, entradas maliciosas y limite por IP"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Grupos administrados por AWS: OWASP comunes, entradas conocidas como
  # maliciosas e inyeccion SQL. Prioridades 1..N.
  dynamic "rule" {
    for_each = { for i, g in var.waf_managed_rule_groups : g => i }

    content {
      name     = rule.key
      priority = rule.value + 1

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  # Freno de fuerza bruta contra Keycloak y la API.
  rule {
    name     = "limite-por-ip"
    priority = 100

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "limite-por-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-waf" })
}

# `count` NO puede depender de var.alb_arn: en un apply desde cero el ARN del
# ALB aun no se conoce en tiempo de plan y Terraform aborta con
# "Invalid count argument". Se decide solo con enable_waf.
resource "aws_wafv2_web_acl_association" "this" {
  count = var.enable_waf ? 1 : 0

  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}
