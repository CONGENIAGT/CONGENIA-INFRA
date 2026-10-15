# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api"        = "1.0.0-880f62b"
  "frontend"   = "1.0.0-9323635"
  "pdf-worker" = "1.0.0-2893d65"
  "keycloak"   = "26.6.1-476a230"
  "migrate"    = "schema-1d5298b"
  "cie10"      = "1.0.0-c0070fc"
}
