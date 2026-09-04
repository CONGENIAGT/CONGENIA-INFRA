output "validation_record_fqdns" {
  description = "Se pasa a aws_acm_certificate_validation para que espere a estos registros."
  value       = [for r in aws_route53_record.cert_validation : r.fqdn]
}
