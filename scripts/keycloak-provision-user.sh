#!/usr/bin/env bash
# Alta o actualizacion de un usuario clinico con la cuenta de servicio
# congenia-provisioner (correccion A3), sin el administrador de master.
#
# El cliente solo tiene manage-users, view-users, query-users y query-groups en
# el realm congenia: puede crear usuarios, asignarlos a los grupos de
# institucion y fijar una clave temporal, nada mas.
#
# Uso:
#   KEYCLOAK_BASE_URL=http://localhost:18080 \
#   KEYCLOAK_PROVISIONER_SECRET=... \
#   scripts/keycloak-provision-user.sh <usuario> "<Nombre Apellido>" <funcion> <tenant>[,<tenant>...]
#
# <funcion> es un subgrupo de /instituciones/<tenant>: medicos, genetistas,
# coordinadores o revisores. La clave temporal se genera aqui, cumple la
# politica del realm, se exige cambiarla en el primer acceso y no se imprime:
# se entrega por KEYCLOAK_TEMP_PASSWORD_FILE (archivo 0600) si se define.
set -euo pipefail

: "${KEYCLOAK_BASE_URL:?Define KEYCLOAK_BASE_URL (tunel privado: http://localhost:18080)}"
: "${KEYCLOAK_PROVISIONER_SECRET:?Define KEYCLOAK_PROVISIONER_SECRET}"
[[ $# -eq 4 ]] || { echo "Uso: $0 <usuario> \"<nombre>\" <funcion> <tenants>" >&2; exit 2; }

username="$1"
display_name="$2"
funcion="$3"
tenants="$4"
[[ "$username" =~ ^[a-z0-9][a-z0-9._-]{2,62}$ ]] || { echo "Usuario invalido" >&2; exit 2; }
case "$funcion" in medicos|genetistas|coordinadores|revisores) ;; *) echo "Funcion invalida" >&2; exit 2 ;; esac
[[ "$tenants" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "Tenants invalidos" >&2; exit 2; }

export KEYCLOAK_CLIENT_ID=congenia-provisioner
export KEYCLOAK_CLIENT_SECRET="$KEYCLOAK_PROVISIONER_SECRET"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
token_cache_dir="$(mktemp -d)"
chmod 700 "$token_cache_dir"
trap 'rm -rf "$token_cache_dir"' EXIT
export KEYCLOAK_ADMIN_TOKEN_CACHE="${token_cache_dir}/token.json"
kc_curl() { python3 "${script_dir}/keycloak-request.py" "$@"; }

realm_url="${KEYCLOAK_BASE_URL%/}/admin/realms/congenia"

first_name="${display_name%% *}"
last_name="${display_name#* }"
[[ "$last_name" != "$display_name" ]] || last_name=""

user_id="$(kc_curl -fsS "${realm_url}/users?exact=true&username=${username}" | jq -er '.[0].id // empty' || true)"
if [[ -z "$user_id" ]]; then
  jq -nc --arg u "$username" --arg f "$first_name" --arg l "$last_name" \
    '{username: $u, firstName: $f, lastName: $l, enabled: true, requiredActions: ["UPDATE_PASSWORD"]}' |
    kc_curl -fsS -o /dev/null -X POST "${realm_url}/users" -d @-
  user_id="$(kc_curl -fsS "${realm_url}/users?exact=true&username=${username}" | jq -er '.[0].id')"
  created=true
else
  created=false
fi

IFS=, read -r -a tenant_list <<<"$tenants"
for tenant in "${tenant_list[@]}"; do
  group_id="$(kc_curl -fsS "${realm_url}/group-by-path/instituciones/${tenant}/${funcion}" | jq -er '.id')" || {
    echo "No existe el grupo /instituciones/${tenant}/${funcion}; crearlo con configure-keycloak-web.sh" >&2
    exit 1
  }
  kc_curl -fsS -o /dev/null -X PUT "${realm_url}/users/${user_id}/groups/${group_id}"
done

if [[ "$created" == true ]]; then
  # 20 caracteres con mayuscula, minuscula y digito garantizados.
  temp_password="$(python3 -c 'import secrets,string
a=string.ascii_letters+string.digits
while True:
    p="".join(secrets.choice(a) for _ in range(20))
    if any(c.islower() for c in p) and any(c.isupper() for c in p) and any(c.isdigit() for c in p):
        print(p); break')"
  jq -nc --arg p "$temp_password" '{type: "password", value: $p, temporary: true}' |
    kc_curl -fsS -o /dev/null -X PUT "${realm_url}/users/${user_id}/reset-password" -d @-
  if [[ -n "${KEYCLOAK_TEMP_PASSWORD_FILE:-}" ]]; then
    (umask 077 && printf '%s\n' "$temp_password" > "$KEYCLOAK_TEMP_PASSWORD_FILE")
  fi
  unset temp_password
fi

kc_curl -fsS "${realm_url}/users/${user_id}/groups" |
  jq -e --args '[.[].path] as $have | all($ARGS.positional[]; . as $p | $have | index($p))' \
    $(for t in "${tenant_list[@]}"; do printf '/instituciones/%s/%s ' "$t" "$funcion"; done) >/dev/null || {
    echo "FALLA: ${username} no quedo en todos sus grupos." >&2
    exit 1
  }

echo "OK: ${username} $([[ "$created" == true ]] && echo creado || echo actualizado) en ${funcion} de ${tenants} con congenia-provisioner."
