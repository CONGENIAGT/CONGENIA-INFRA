#!/usr/bin/env bash
# =============================================================================
# Pruebas de salud atravesando el ALB, que es el unico punto de entrada.
#
# Comprueba CONTENIDO, no solo codigos HTTP: con las reglas de path mal
# aplicadas, MiniStack devuelve 200 sirviendo el frontend para todas las rutas,
# y un smoke test que solo mirara el codigo daria un falso verde.
# =============================================================================
set -uo pipefail

TFDIR="${1:-envs/local}"
GW="${MINISTACK_ENDPOINT:-http://localhost:4566}"

alb=$(cd "$TFDIR" && terraform output -raw alb_name)
host="${alb}.alb.localhost"

fail=0
check() {
  local label="$1" path="$2" pattern="$3"
  local body code
  body=$(curl -s -m 15 -H "Host: ${host}" "${GW}${path}")
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -H "Host: ${host}" "${GW}${path}")

  if grep -qE "$pattern" <<<"$body"; then
    printf '  OK     %-22s %-18s %s\n' "$label" "$path" "$code"
  else
    printf '  FALLA  %-22s %-18s %s  (no coincide con /%s/)\n' \
      "$label" "$path" "$code" "$pattern"
    fail=1
  fi
}

echo "Smoke test contra ALB ${alb} (Host: ${host})"
echo "  ruta                            path               http"
check "frontend (ficha)"  "/"                 'Ficha Genetica|<!doctype html>'
check "api"               "/v1/ping"          '"success"|"message"'
check "keycloak"          "/realms/master"    '"realm"|"public_key"|"token-service"'

if [[ $fail -eq 0 ]]; then
  echo "Todo el trafico atraviesa la DMZ hacia la red privada correctamente."
else
  echo "Hay rutas que no llegan a su servicio."
fi
exit $fail
