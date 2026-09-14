# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api"        = "1.0.0-415cff9"
  "frontend"   = "1.0.0-7d3effb"
  "pdf-worker" = "1.0.0-47fb71e"
  "keycloak"   = "26.6.1-925d47b"
  "migrate"    = "schema-70abe44"
}
