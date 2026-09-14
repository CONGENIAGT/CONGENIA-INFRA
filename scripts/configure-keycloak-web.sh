#!/usr/bin/env bash
set -euo pipefail

: "${KEYCLOAK_BASE_URL:?Define KEYCLOAK_BASE_URL, por ejemplo https://cogenia.app}"
: "${KEYCLOAK_ADMIN_PASSWORD:?Define KEYCLOAK_ADMIN_PASSWORD}"
: "${KEYCLOAK_MEDICO_PASSWORD:?Define KEYCLOAK_MEDICO_PASSWORD para la clave temporal}"

admin_user="${KEYCLOAK_ADMIN_USERNAME:-admin}"
medico_user="${KEYCLOAK_MEDICO_USERNAME:-medico.inicial}"
medico_name="${KEYCLOAK_MEDICO_NAME:-Medico Inicial}"
medico_specialty="${KEYCLOAK_MEDICO_SPECIALTY:-Genetica Clinica}"
medico_tenants="${KEYCLOAK_MEDICO_TENANTS:-254}"
medico_realm_roles="${KEYCLOAK_MEDICO_REALM_ROLES:-medico,congenia-admin}"
base_url="${KEYCLOAK_BASE_URL%/}"
realm_url="${base_url}/admin/realms/congenia"

token="$({
  curl -fsS "${base_url}/realms/master/protocol/openid-connect/token" \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=admin-cli \
    --data-urlencode "username=${admin_user}" \
    --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}"
} | jq -er '.access_token')"

auth=(-H "Authorization: Bearer ${token}" -H 'Content-Type: application/json')
target_scopes_url="${realm_url}/client-scopes"
master_scopes_url="${base_url}/admin/realms/master/client-scopes"

scope_id() {
  local scopes_url="$1"
  local scope_name="$2"
  curl -fsS "${auth[@]}" "$scopes_url" |
    jq -er --arg name "$scope_name" '.[] | select(.name == $name) | .id' |
    head -n 1
}

ensure_standard_scope() {
  local scope_name="$1"
  local source_id
  local source_json
  local target_id
  local scope_payload

  source_id="$(scope_id "$master_scopes_url" "$scope_name")"
  source_json="$(curl -fsS "${auth[@]}" "${master_scopes_url}/${source_id}")"
  target_id="$(scope_id "$target_scopes_url" "$scope_name" || true)"
  scope_payload="$(jq -a 'del(.id, .protocolMappers)' <<<"$source_json")"

  if [[ -z "$target_id" ]]; then
    curl -fsS -o /dev/null -X POST "${auth[@]}" "$target_scopes_url" -d "$scope_payload"
    target_id="$(scope_id "$target_scopes_url" "$scope_name")"
  else
    curl -fsS -o /dev/null -X PUT "${auth[@]}" \
      "${target_scopes_url}/${target_id}" -d "$scope_payload"
  fi

  while IFS= read -r mapper; do
    local mapper_name
    local mapper_id
    local mapper_payload

    mapper_name="$(jq -er '.name' <<<"$mapper")"
    mapper_id="$({
      curl -fsS "${auth[@]}" "${target_scopes_url}/${target_id}/protocol-mappers/models"
    } | jq -er --arg name "$mapper_name" '.[] | select(.name == $name) | .id' | head -n 1 || true)"

    if [[ -z "$mapper_id" ]]; then
      mapper_payload="$(jq -a 'del(.id)' <<<"$mapper")"
      curl -fsS -o /dev/null -X POST "${auth[@]}" \
        "${target_scopes_url}/${target_id}/protocol-mappers/models" -d "$mapper_payload"
    else
      mapper_payload="$(jq --arg id "$mapper_id" '.id = $id' <<<"$mapper")"
      curl -fsS -o /dev/null -X PUT "${auth[@]}" \
        "${target_scopes_url}/${target_id}/protocol-mappers/models/${mapper_id}" \
        -d "$mapper_payload"
    fi
  done < <(jq -c '.protocolMappers[]' <<<"$source_json")

  local expected_mappers
  local actual_mappers
  expected_mappers="$(jq -c '[.protocolMappers[].name] | sort' <<<"$source_json")"
  actual_mappers="$({
    curl -fsS "${auth[@]}" "${target_scopes_url}/${target_id}/protocol-mappers/models"
  } | jq -c '[.[].name] | sort')"

  jq -e --argjson expected "$expected_mappers" --argjson actual "$actual_mappers" \
    '$expected - $actual | length == 0' <<<null >/dev/null || {
      echo "FALLA: el scope ${scope_name} no contiene todos sus mappers estándar." >&2
      return 1
    }
}

for standard_scope in basic profile email roles; do
  ensure_standard_scope "$standard_scope"
done

ensure_role() {
  local role_name="$1"
  local description="$2"

  if ! curl -fsS -o /dev/null "${auth[@]}" "${realm_url}/roles/${role_name}" 2>/dev/null; then
    jq -nca --arg name "$role_name" --arg description "$description" \
      '{name: $name, description: $description}' |
      curl -fsS -o /dev/null -X POST "${auth[@]}" "${realm_url}/roles" -d @-
  fi
}

ensure_role "medico" "Puede iniciar fichas clinicas desde el cliente web"
ensure_role "congenia-admin" "Puede revisar y resolver adendas en el dashboard"

client_json="$(jq -nca --arg origin "$base_url" '{
  clientId: "congenia-web",
  name: "CONGENIA — Aplicacion web",
  enabled: true,
  publicClient: true,
  standardFlowEnabled: true,
  implicitFlowEnabled: false,
  directAccessGrantsEnabled: false,
  serviceAccountsEnabled: false,
  protocol: "openid-connect",
  redirectUris: [($origin + "/*")],
  webOrigins: [$origin],
  attributes: {
    "pkce.code.challenge.method": "S256",
    "post.logout.redirect.uris": ($origin + "/*")
  },
  protocolMappers: [
    {
      name: "especialidad",
      protocol: "openid-connect",
      protocolMapper: "oidc-usermodel-attribute-mapper",
      consentRequired: false,
      config: {
        "user.attribute": "especialidad",
        "claim.name": "especialidad",
        "jsonType.label": "String",
        "access.token.claim": "true",
        "id.token.claim": "true",
        "userinfo.token.claim": "true",
        "multivalued": "false"
      }
    },
    {
      name: "tenants",
      protocol: "openid-connect",
      protocolMapper: "oidc-usermodel-attribute-mapper",
      consentRequired: false,
      config: {
        "user.attribute": "tenants",
        "claim.name": "tenants",
        "jsonType.label": "String",
        "access.token.claim": "true",
        "id.token.claim": "false",
        "userinfo.token.claim": "true",
        "multivalued": "true"
      }
    },
    {
      name: "congenia-api-audience",
      protocol: "openid-connect",
      protocolMapper: "oidc-audience-mapper",
      consentRequired: false,
      config: {
        "included.custom.audience": "congenia-api",
        "access.token.claim": "true",
        "id.token.claim": "false"
      }
    }
  ]
}')"

client_uuid="$(curl -fsS "${auth[@]}" "${realm_url}/clients?clientId=congenia-web" | jq -er '.[0].id // empty' || true)"
if [[ -z "$client_uuid" ]]; then
  curl -fsS -o /dev/null -X POST "${auth[@]}" "${realm_url}/clients" -d "$client_json"
  client_uuid="$(curl -fsS "${auth[@]}" "${realm_url}/clients?clientId=congenia-web" | jq -er '.[0].id')"
else
  curl -fsS -o /dev/null -X PUT "${auth[@]}" "${realm_url}/clients/${client_uuid}" -d "$client_json"
fi

for standard_scope in basic profile email roles; do
  standard_scope_id="$(scope_id "$target_scopes_url" "$standard_scope")"
  curl -fsS -o /dev/null -X PUT "${auth[@]}" \
    "${realm_url}/clients/${client_uuid}/default-client-scopes/${standard_scope_id}"
done

user_uuid="$(curl -fsS "${auth[@]}" "${realm_url}/users?exact=true&username=${medico_user}" | jq -er '.[0].id // empty' || true)"
tenants_json="$(jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))' <<<"$medico_tenants")"
if [[ -z "$user_uuid" ]]; then
  user_json="$(jq -nca \
    --arg username "$medico_user" \
    --arg name "$medico_name" \
    --arg specialty "$medico_specialty" \
    --argjson tenants "$tenants_json" \
    --arg password "$KEYCLOAK_MEDICO_PASSWORD" \
    '{
      username: $username,
      enabled: true,
      firstName: $name,
      attributes: {especialidad: [$specialty], tenants: $tenants},
      credentials: [{type: "password", value: $password, temporary: true}]
    }')"
  curl -fsS -o /dev/null -X POST "${auth[@]}" "${realm_url}/users" -d "$user_json"
  user_uuid="$(curl -fsS "${auth[@]}" "${realm_url}/users?exact=true&username=${medico_user}" | jq -er '.[0].id')"
else
  user_json="$(curl -fsS "${auth[@]}" "${realm_url}/users/${user_uuid}" |
    jq -ca \
      --arg name "$medico_name" \
      --arg specialty "$medico_specialty" \
      --argjson tenants "$tenants_json" \
      '.firstName = $name
       | .enabled = true
       | .attributes = ((.attributes // {}) + {especialidad: [$specialty], tenants: $tenants})')"
  curl -fsS -o /dev/null -X PUT "${auth[@]}" "${realm_url}/users/${user_uuid}" -d "$user_json"
fi

roles_json="$(
  jq -Rr 'split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0)' <<<"$medico_realm_roles" |
  while IFS= read -r role_name; do
    curl -fsS "${auth[@]}" "${realm_url}/roles/${role_name}"
  done |
  jq -s '.'
)"
assigned_roles="$(curl -fsS "${auth[@]}" "${realm_url}/users/${user_uuid}/role-mappings/realm")"
missing_roles="$(jq -nca --argjson desired "$roles_json" --argjson assigned "$assigned_roles" '
  $desired | map(select(.name as $role_name | all($assigned[]?; .name != $role_name)))
')"
if [[ "$(jq -r 'length' <<<"$missing_roles")" -gt 0 ]]; then
  curl -fsS -o /dev/null -X POST "${auth[@]}" \
    "${realm_url}/users/${user_uuid}/role-mappings/realm" \
    -d "$missing_roles"
fi

client_defaults="$(curl -fsS "${auth[@]}" "${realm_url}/clients/${client_uuid}/default-client-scopes")"
for standard_scope in profile email roles; do
  jq -e --arg name "$standard_scope" 'any(.name == $name)' <<<"$client_defaults" >/dev/null || {
    echo "FALLA: congenia-web no tiene ${standard_scope} como default client scope." >&2
    exit 1
  }
done

curl -fsS "${auth[@]}" "${realm_url}/clients/${client_uuid}" |
  jq -e '
    .enabled == true and
    .publicClient == true and
    .standardFlowEnabled == true and
    .attributes["pkce.code.challenge.method"] == "S256" and
    any(.protocolMappers[]?; .name == "tenants" and .config["access.token.claim"] == "true")
  ' >/dev/null || {
    echo 'FALLA: congenia-web no conserva PKCE S256 o el mapper tenants.' >&2
    exit 1
  }

user_roles="$(curl -fsS "${auth[@]}" "${realm_url}/users/${user_uuid}/role-mappings/realm")"
jq -Rr 'split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0)' <<<"$medico_realm_roles" |
while IFS= read -r role_name; do
  jq -e --arg name "$role_name" 'any(.name == $name)' <<<"$user_roles" >/dev/null || {
    echo "FALLA: ${medico_user} no tiene el rol ${role_name}." >&2
    exit 1
  }
done

curl -fsS "${auth[@]}" "${realm_url}/users/${user_uuid}" |
  jq -e --argjson tenants "$tenants_json" '
    (.attributes.tenants // []) == $tenants and
    ((.attributes.especialidad // [])[0] | length > 0)
  ' >/dev/null || {
    echo "FALLA: ${medico_user} no tiene tenants/especialidad configurados." >&2
    exit 1
  }

authorization_probe="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -G \
  "${base_url}/realms/congenia/protocol/openid-connect/auth" \
  --data-urlencode client_id=congenia-web \
  --data-urlencode response_type=code \
  --data-urlencode 'scope=openid profile email' \
  --data-urlencode "redirect_uri=${base_url}/" \
  --data-urlencode state=scope-verification \
  --data-urlencode code_challenge=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
  --data-urlencode code_challenge_method=S256)"
case "$authorization_probe" in
  200\ *|302\ *) ;;
  *)
    echo "FALLA: el endpoint OIDC rechazo la solicitud de verificacion (${authorization_probe})." >&2
    exit 1
    ;;
esac
if [[ "$authorization_probe" == *invalid_scope* ]]; then
  echo 'FALLA: Keycloak todavía devuelve invalid_scope para openid profile email.' >&2
  exit 1
fi

echo "OK: congenia-web verificado con scopes profile, email, roles y tenants; usuario ${medico_user} configurado."
