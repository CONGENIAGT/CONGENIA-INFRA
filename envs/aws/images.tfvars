# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api"        = "1.0.0-6317351"
  "frontend"   = "1.0.0-a9a3359"
  "pdf-worker" = "1.0.0-2893d65"
  "keycloak"   = "26.6.1-eb28081"
  "cie10"      = "1.0.0-2a8457c"
  "migrate"    = "schema-681e091"
}
