output "task_definition_arn" {
  description = "ARN con revision incluida: `make migrate` corre exactamente lo declarado."
  value       = aws_ecs_task_definition.this.arn
}

output "task_definition_family" {
  value = aws_ecs_task_definition.this.family
}
