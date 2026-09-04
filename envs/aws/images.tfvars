# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api"        = "1.0.0-f2a2352"
  "frontend"   = "1.0.0-83cd2eb"
  "pdf-worker" = "1.0.0-224c334"
  "keycloak"   = "26.6.1-2791082"
  "migrate"    = "schema-f2a2352"
}
