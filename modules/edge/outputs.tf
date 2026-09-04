output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_name" {
  value = aws_lb.this.name
}

output "target_group_arns" {
  value = { for k, v in aws_lb_target_group.this : k => v.arn }
}

output "listener_arn" {
  description = "Listener 80. Con TLS encendido solo redirige."
  value       = aws_lb_listener.http.arn
}

output "https_listener_arn" {
  description = "Listener 443, o null si el entorno no tiene certificado."
  value       = one(aws_lb_listener.https[*].arn)
}

output "rule_arns" {
  description = "ARN de la regla de listener por servicio (sin el destino por defecto)."
  value       = { for k, v in aws_lb_listener_rule.this : k => v.arn }
}

output "routes" {
  description = "Eco de las rutas configuradas, para la reconciliacion local."
  value       = { for k, v in var.routes : k => v.paths }
}

output "alb_zone_id" {
  description = "Zona alojada del propio ALB. La necesita el registro ALIAS de Route 53."
  value       = aws_lb.this.zone_id
}
