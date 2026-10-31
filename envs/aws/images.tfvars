# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api"        = "1.0.0-50d4a4d"
  "frontend"   = "1.0.0-2be5349"
  "pdf-worker" = "1.0.0-a2fbcdb"
  "keycloak"   = "26.6.1-64dac06"
  "cie10"      = "1.0.0-84e691a"
  "migrate"    = "schema-5ec4291"
}
