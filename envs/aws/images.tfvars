# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api"        = "1.0.0-f2a2352"
  "frontend"   = "1.0.0-5b1b7d1"
  "pdf-worker" = "1.0.0-224c334"
  "keycloak"   = "26.6.1-3c83c1e"
  "migrate"    = "schema-f2a2352"
}
