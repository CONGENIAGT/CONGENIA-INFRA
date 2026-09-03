# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api" = "1.0.0-7132058"
  "frontend" = "1.0.0-3d92ee2"
  "pdf-worker" = "1.0.0-224c334"
  "keycloak" = "26.6.1-5b04264"
  "migrate" = "schema-f2a2352"
}
