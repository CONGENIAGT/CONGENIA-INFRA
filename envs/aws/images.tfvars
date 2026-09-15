# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api"        = "1.0.0-415cff9"
  "frontend"   = "1.0.0-1a27004"
  "pdf-worker" = "1.0.0-921f485"
  "keycloak"   = "26.6.1-d489008"
  "migrate"    = "schema-5061b6c"
}
