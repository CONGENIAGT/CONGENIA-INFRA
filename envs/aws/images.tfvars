# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api"        = "1.0.0-9c55484"
  "frontend"   = "1.0.0-83cd2eb"
  "pdf-worker" = "1.0.0-47fb71e"
  "keycloak"   = "26.6.1-2791082"
  "migrate"    = "schema-55f6e2a"
}
