#!/usr/bin/env bash
set -euo pipefail

TFDIR="${1:-envs/local}"
ORCH_DIR="${2:-../ProjectUVG}"
SQL_DIR="${ORCH_DIR}/CONGENIA-M1-SERVER/db/init"

command -v docker >/dev/null || {
  echo "Falta Docker para cargar el esquema local." >&2
  exit 1
}

[[ -d "$SQL_DIR" ]] || {
  echo "No encuentro el esquema en ${SQL_DIR}." >&2
  exit 1
}

mapfile_compat() {
  while IFS= read -r line; do
    sql_files+=("$line")
  done
}

sql_files=()
mapfile_compat < <(find "$SQL_DIR" -maxdepth 1 -type f -name '*.sql' -print | sort)
(( ${#sql_files[@]} > 0 )) || {
  echo "No hay archivos SQL en ${SQL_DIR}." >&2
  exit 1
}

db_endpoint=$(cd "$TFDIR" && terraform output -raw db_endpoint)
db_host="${db_endpoint%%:*}"

rds_container=""
while IFS= read -r container; do
  while IFS= read -r ip; do
    if [[ "$ip" == "$db_host" ]]; then
      rds_container="$container"
      break 2
    fi
  done < <(docker inspect "$container" --format '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}')
done < <(docker ps -q --filter label=ministack=rds)

[[ -n "$rds_container" ]] || {
  echo "No encuentro el contenedor RDS de MiniStack para ${db_endpoint}." >&2
  exit 1
}

table_count=$(docker exec "$rds_container" \
  psql -U congenia -d congenia -Atc \
  "SELECT count(*) FROM pg_tables WHERE schemaname = 'public';")

if [[ "$table_count" == "0" ]]; then
  echo "Cargando esquema y catalogos en PostgreSQL local..."
  (
    for sql_file in "${sql_files[@]}"; do
      printf '\n\\echo Aplicando %s\n' "$(basename "$sql_file")"
      sed -n '1,$p' "$sql_file"
    done
  ) | docker exec -i "$rds_container" \
    psql -v ON_ERROR_STOP=1 --single-transaction -U congenia -d congenia
fi

verification=$(docker exec "$rds_container" \
  psql -U congenia -d congenia -Atc \
  "SELECT
     to_regclass('public.usuario') IS NOT NULL
     AND to_regclass('public.ficha_clinica') IS NOT NULL
     AND to_regclass('public.consentimiento') IS NOT NULL
     AND EXISTS (SELECT 1 FROM referido_de)
     AND EXISTS (SELECT 1 FROM sistema_externo WHERE system_id = 'sadc');")

[[ "$verification" == "t" ]] || {
  echo "La base local existe, pero su esquema o catalogos estan incompletos." >&2
  echo "Ejecuta make destroy ENV=local y repite make up ENV=local." >&2
  exit 1
}

echo "Esquema y catalogos locales verificados."
