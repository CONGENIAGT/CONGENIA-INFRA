# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api"        = "1.0.0-c7f7ca2"
  "frontend"   = "1.0.0-d6291b5"
  "pdf-worker" = "1.0.0-2893d65"
  "keycloak"   = "26.6.1-eb28081"
  "cie10"      = "1.0.0-1762314"
  "migrate"    = "schema-148943d"
}
