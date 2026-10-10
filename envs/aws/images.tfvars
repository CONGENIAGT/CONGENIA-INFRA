# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api"        = "1.0.0-9332cc4"
  "frontend"   = "1.0.0-11cb01f"
  "pdf-worker" = "1.0.0-921f485"
  "keycloak"   = "26.6.1-b1757b3"
  "migrate"    = "schema-2fe495a"
}
