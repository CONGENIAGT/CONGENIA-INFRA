# Generado por scripts/release-plan.sh — que imagen corre cada servicio.
# Se aplica con: terraform apply -var-file=images.tfvars
image_tags = {
  "api"        = "1.0.0-435ec99"
  "frontend"   = "1.0.0-f8aba9e"
  "pdf-worker" = "1.0.0-2893d65"
  "keycloak"   = "26.6.1-eb28081"
  "migrate"    = "schema-1ad4bc7"
  "cie10"      = "1.0.0-212eda6"
}
