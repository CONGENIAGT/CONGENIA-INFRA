#!/usr/bin/env bash
# Ciclo de vida independiente. Nunca aplica envs/aws ni envs/shared.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ACTION=${1:-status}
TF=${TERRAFORM:-terraform}
CORE=${DB_ACCESS_CORE_DIR:-$ROOT/envs/aws}
STACK=${DB_ACCESS_DIR:-$ROOT/envs/db-access}
CONFIG="$STACK/connection.auto.tfvars.json"
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}
PREFIX=${TF_VAR_name_prefix:-congenia}
ENVIRONMENT=${TF_VAR_environment:-prod}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "ERROR: $*" >&2; exit 1; }
case "$ACTION" in plan|up|status|tunnel|stop|destroy|verify) ;; *) fail "Accion desconocida: $ACTION" ;; esac
for bin in aws jq; do command -v "$bin" >/dev/null || fail "Falta $bin"; done
export AWS_PAGER=""

if [[ -f "$CONFIG" ]]; then
  jq -e '.connection.version == 1' "$CONFIG" >/dev/null || fail "Contrato local invalido: $CONFIG"
  REGION=$(jq -r '.connection.region' "$CONFIG")
  PREFIX=$(jq -r '.connection.name_prefix' "$CONFIG")
  ENVIRONMENT=$(jq -r '.connection.environment' "$CONFIG")
fi
[[ "$PREFIX" =~ ^[a-zA-Z0-9-]+$ && "$ENVIRONMENT" =~ ^[a-zA-Z0-9-]+$ ]] || fail "Prefijo/entorno invalido"
NAME="$PREFIX-$ENVIRONMENT-db-access"
ACCOUNT=$(aws sts get-caller-identity --region "$REGION" --query Account --output text)
if [[ -f "$CONFIG" ]]; then
  [[ "$ACCOUNT" == "$(jq -r '.connection.account_id' "$CONFIG")" ]] || fail "El contrato pertenece a otra cuenta AWS"
fi
awsq() { aws --region "$REGION" "$@"; }
tf() { "$TF" -chdir="$STACK" "$@"; }

instances() {
  awsq ec2 describe-instances --filters \
    "Name=tag:Project,Values=CONGENIA" "Name=tag:Component,Values=db-access" \
    "Name=tag:Name,Values=$NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --output json > "$WORK/instances.json"
  jq '[.Reservations[].Instances[]]' "$WORK/instances.json" > "$WORK/nodes.json"
  COUNT=$(jq length "$WORK/nodes.json")
  [[ "$COUNT" -le 1 ]] || fail "Hay $COUNT instancias $NAME; revisar duplicados antes de operar"
  INSTANCE=$(jq -r '.[0].InstanceId // empty' "$WORK/nodes.json")
  STATE=$(jq -r '.[0].State.Name // "absent"' "$WORK/nodes.json")
}

# Auditoria contra AWS, incluso si el estado Terraform esta vacio. Ninguna
# excepcion de API puede confundirse con un inventario vacio.
inventory() {
  local filters=("Name=tag:Project,Values=CONGENIA" "Name=tag:Component,Values=db-access" "Name=tag:Environment,Values=$ENVIRONMENT")
  awsq ec2 describe-volumes --filters "${filters[@]}" "Name=tag:Name,Values=$NAME-root" > "$WORK/volumes.json"
  awsq ec2 describe-security-groups --filters "${filters[@]}" "Name=group-name,Values=$NAME" > "$WORK/groups.json"
  awsq ec2 describe-security-group-rules --filters "${filters[@]}" > "$WORK/rules.json"
  awsq ec2 describe-snapshots --owner-ids self --filters "${filters[@]}" > "$WORK/snapshots.json"
  awsq iam list-roles --path-prefix /congenia/db-access/ > "$WORK/roles.json"
  awsq iam list-instance-profiles --path-prefix /congenia/db-access/ > "$WORK/profiles.json"
  awsq iam list-policies --scope Local --path-prefix /congenia/db-access/ > "$WORK/policies.json"
  awsq ssm list-documents --filters "Key=Owner,Values=Self" "Key=Name,Values=$NAME" > "$WORK/documents.json"
  jq -n --arg name "$NAME" --argjson nodes "$(cat "$WORK/nodes.json")" \
    --slurpfile v "$WORK/volumes.json" --slurpfile g "$WORK/groups.json" \
    --slurpfile r "$WORK/rules.json" --slurpfile s "$WORK/snapshots.json" \
    --slurpfile roles "$WORK/roles.json" --slurpfile p "$WORK/profiles.json" \
    --slurpfile policies "$WORK/policies.json" --slurpfile d "$WORK/documents.json" '
    {instances: [$nodes[].InstanceId], volumes: [$v[0].Volumes[].VolumeId],
     security_groups: [$g[0].SecurityGroups[].GroupId],
     rules: [$r[0].SecurityGroupRules[] | select(any(.Tags[]?; .Key == "Name" and .Value == $name)) | .SecurityGroupRuleId],
     snapshots: [$s[0].Snapshots[] | select(any(.Tags[]?; .Key == "Name" and (.Value | startswith($name)))) | .SnapshotId],
     roles: [$roles[0].Roles[] | select(.RoleName == $name) | .RoleName],
     profiles: [$p[0].InstanceProfiles[] | select(.InstanceProfileName == $name) | .InstanceProfileName],
     policies: [$policies[0].Policies[] | select(.PolicyName == ($name + "-operator")) | .Arn],
     documents: [$d[0].DocumentIdentifiers[] | select(.Name == $name) | .Name]}' > "$WORK/inventory.json"
  local groups
  groups=$(jq -r '.security_groups | join(",")' "$WORK/inventory.json")
  if [[ -n "$groups" ]]; then
    awsq ec2 describe-network-interfaces --filters "Name=group-id,Values=$groups" > "$WORK/enis.json"
    jq --slurpfile enis "$WORK/enis.json" '. + {enis: [$enis[0].NetworkInterfaces[].NetworkInterfaceId]}' \
      "$WORK/inventory.json" > "$WORK/with-enis.json"
    mv "$WORK/with-enis.json" "$WORK/inventory.json"
  fi
}

verify() {
  instances
  inventory
  jq . "$WORK/inventory.json"
  jq -e 'all(.[]; length == 0)' "$WORK/inventory.json" >/dev/null || fail "Quedan recursos de $NAME; no se declara limpio"
  echo "$NAME: ausente en AWS. El estado remoto se conserva."
}

prepare() {
  command -v "$TF" >/dev/null || fail "Falta Terraform"
  # Solo leer el output especifico: el estado principal contiene secretos.
  "$TF" -chdir="$CORE" output -json db_access_context > "$WORK/context.json"
  jq -e --arg account "$ACCOUNT" '.version == 1 and .account_id == $account and .db_port == 5432' \
    "$WORK/context.json" >/dev/null || fail "Aplicar primero el cambio de reglas y outputs de envs/aws"
  # Comprobar que la migracion de representacion de reglas ya esta en estado.
  "$TF" -chdir="$CORE" state list > "$WORK/core-state"
  for address in data_postgres data_redis data_vpc; do
    rg_pattern="module.network.aws_vpc_security_group_(ingress|egress)_rule.$address"
    grep -Eq "^${rg_pattern}$" "$WORK/core-state" || fail "Falta importar/aplicar la regla $address"
  done
  jq '{connection: .}' "$WORK/context.json" > "$WORK/config.json"
  if [[ -f "$CONFIG" ]]; then
    diff -q <(jq -S . "$CONFIG") <(jq -S . "$WORK/config.json") >/dev/null || \
      fail "Cambio el destino/cuenta del contrato. Destruye el acceso anterior antes de renovar el contrato local"
  else
    mkdir -p "$STACK"
    cp "$WORK/config.json" "$CONFIG"
    chmod 600 "$CONFIG"
  fi
  REGION=$(jq -r '.connection.region' "$CONFIG")
  PREFIX=$(jq -r '.connection.name_prefix' "$CONFIG")
  ENVIRONMENT=$(jq -r '.connection.environment' "$CONFIG")
  NAME="$PREFIX-$ENVIRONMENT-db-access"
  tf init -input=false
}

online() {
  local ping
  for ((attempt=1; attempt<=60; attempt++)); do
    ping=$(awsq ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE" \
      --query 'InstanceInformationList[0].PingStatus' --output text)
    [[ "$ping" == "Online" ]] && return 0
    [[ $((attempt % 6)) == 0 ]] && echo "Esperando SSM en $INSTANCE ($((attempt * 5))s)..."
    sleep 5
  done
  fail "SSM no quedo Online. La EC2 sigue encendida; usar make db-access-stop si no vas a diagnosticarla"
}

case "$ACTION" in
  plan|up)
    prepare
    tf plan -input=false -out="$WORK/access.tfplan"
    [[ "$ACTION" == plan ]] && exit 0
    tf show -json "$WORK/access.tfplan" > "$WORK/plan.json"
    jq -e '[.resource_changes[]? | select(.change.actions | index("delete"))] | length == 0' \
      "$WORK/plan.json" >/dev/null || fail "El plan elimina/reemplaza recursos. Revisar db-access-plan y destruir/recrear de forma explicita"
    tf apply -input=false "$WORK/access.tfplan"
    instances
    [[ -n "$INSTANCE" ]] || fail "No aparece la EC2 despues del apply"
    if [[ "$STATE" == stopping ]]; then
      awsq ec2 wait instance-stopped --instance-ids "$INSTANCE"
      STATE=stopped
    fi
    if [[ "$STATE" == stopped ]]; then
      awsq ec2 start-instances --instance-ids "$INSTANCE" >/dev/null
    fi
    awsq ec2 wait instance-running --instance-ids "$INSTANCE"
    online
    echo "$NAME: encendido, SSM Online. Abrir con make db-access-tunnel"
    ;;
  status)
    instances
    inventory
    echo "Cuenta: $ACCOUNT | Region: $REGION | Componente: $NAME"
    jq . "$WORK/inventory.json"
    if [[ "$STATE" == absent ]]; then
      if jq -e 'all(.[]; length == 0)' "$WORK/inventory.json" >/dev/null; then
        echo "Estado: ausente"
      else
        echo "Estado: incompleto (sin EC2, con recursos auxiliares)"
      fi
    else
      if ! jq -e '.instances|length == 1' "$WORK/inventory.json" >/dev/null; then
        fail "Inventario inconsistente"
      fi
      if ! jq -e '(.volumes|length)==1 and (.security_groups|length)==1 and (.rules|length)==3 and (.roles|length)==1 and (.profiles|length)==1 and (.policies|length)==1 and (.documents|length)==1' "$WORK/inventory.json" >/dev/null; then
        echo "Estado: incompleto (faltan recursos auxiliares; revisar el inventario)"
      fi
      echo "Estado EC2: $STATE | Instancia: $INSTANCE"
      awsq ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE" \
        --query 'InstanceInformationList[].{SSM:PingStatus,Agent:AgentVersion}' --output table
      echo "Coste: EBS persiste mientras exista el volumen; EC2 consume computo si esta encendida."
    fi
    [[ ! -f "$CONFIG" ]] || jq -r '.connection | "Destino: \(.db_host):\(.db_port) / \(.db_name)"' "$CONFIG"
    ;;
  stop)
    instances
    [[ -n "$INSTANCE" ]] || { echo "$NAME: sin EC2 que detener"; exit 0; }
    if [[ "$STATE" == pending ]]; then awsq ec2 wait instance-running --instance-ids "$INSTANCE"; STATE=running; fi
    case "$STATE" in
      stopped) echo "$NAME: ya detenido"; exit 0 ;;
      running) awsq ec2 stop-instances --instance-ids "$INSTANCE" >/dev/null ;;
      stopping) ;;
      *) fail "Estado $STATE: no se puede detener ahora" ;;
    esac
    awsq ec2 wait instance-stopped --instance-ids "$INSTANCE"
    echo "$NAME: detenido. Se cortaron sus tuneles; EBS sigue facturandose."
    ;;
  tunnel)
    command -v session-manager-plugin >/dev/null || fail "Instala el Session Manager plugin para AWS CLI en tu Mac (ver docs/DEPLOY.md)"
    PORT=${DB_ACCESS_LOCAL_PORT:-15432}
    [[ "$PORT" =~ ^[0-9]{1,5}$ ]] && ((10#$PORT >= 1 && 10#$PORT <= 65535)) || fail "Puerto local invalido"
    instances
    [[ "$STATE" == running ]] || fail "Estado $STATE. Ejecuta make db-access-up"
    online
    echo "DBeaver: 127.0.0.1:$PORT; PostgreSQL congenia; SSL con CA de RDS. Ctrl-C cierra el tunel; no detiene EC2."
    awsq ssm start-session --target "$INSTANCE" --document-name "$NAME" \
      --parameters "$(jq -nc --arg port "$PORT" '{localPortNumber:[$port]}')"
    ;;
  destroy)
    [[ "${CONFIRM_DESTROY:-}" == destroy-congenia-db-access ]] || fail "Usa CONFIRM_DESTROY=destroy-congenia-db-access"
    command -v "$TF" >/dev/null || fail "Falta Terraform"
    tf init -input=false
    tf show -json > "$WORK/state.json"
    if jq -e '[.. | objects | select(.mode? == "managed" and has("address"))] | length > 0' "$WORK/state.json" >/dev/null; then
      # Recuperar el contrato de este stack, no el de una VPC recreada.
      if [[ ! -f "$CONFIG" ]]; then
        tf output -json access | jq '{connection: .connection}' > "$WORK/config.json"
        jq -e '.connection.version == 1' "$WORK/config.json" >/dev/null || fail "Stack parcial: recuperar su connection.auto.tfvars.json antes de destruir"
        cp "$WORK/config.json" "$CONFIG"
        chmod 600 "$CONFIG"
      fi
      [[ "$ACCOUNT" == "$(jq -r '.connection.account_id' "$CONFIG")" ]] || fail "Cuenta incorrecta"
      REGION=$(jq -r '.connection.region' "$CONFIG")
      PREFIX=$(jq -r '.connection.name_prefix' "$CONFIG")
      ENVIRONMENT=$(jq -r '.connection.environment' "$CONFIG")
      NAME="$PREFIX-$ENVIRONMENT-db-access"
      tf destroy -input=false -auto-approve
    fi
    # EC2/EBS/ENI pueden tardar en desaparecer tras el destroy de Terraform.
    for ((attempt=1; attempt<=12; attempt++)); do
      instances
      inventory
      if jq -e 'all(.[]; length == 0)' "$WORK/inventory.json" >/dev/null; then
        rm -f "$CONFIG"
        echo "$NAME: eliminado y verificado en AWS."
        exit 0
      fi
      echo "Esperando eliminacion de recursos ($attempt/12)..."
      sleep 5
    done
    jq . "$WORK/inventory.json"
    fail "La limpieza no esta completa; conserva el contrato y ejecuta db-access-verify"
    ;;
  verify) verify ;;
esac
