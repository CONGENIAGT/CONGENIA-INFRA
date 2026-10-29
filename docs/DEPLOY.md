# CONGENIA: desplegar y apagar en AWS

Documento unico del ciclo de vida de la infraestructura: preparar la cuenta,
desplegar, y apagar.

La **parte 1** se hace una sola vez por cuenta AWS. Despues, desplegar es
`make up-aws` y todo lo demas esta en las partes 2 y 3.

Los dos stacks principales tienen estos ciclos; el acceso opcional
`envs/db-access` usa un tercer estado y se elimina antes de `envs/aws`:

| | `envs/shared` | `envs/aws` |
|---|---|---|
| Contiene | ECR, OIDC, rol de CI, zona Route 53 | VPC, NAT, ALB, RDS, Redis, ECS, secretos |
| Cuesta | menos de USD 1/mes | practicamente todo el gasto |
| Lo destruye | `make nuke` | `make destroy ENV=aws` |

> Esta infraestructura consume creditos reales. NAT, ALB, RDS y Redis cobran
> aunque no haya trafico.

---

# Parte 1 — Preparar la cuenta (una sola vez)

## 1.1 Herramientas

```bash
brew install git terraform awscli jq node@22
brew install --cask docker
export PATH="$(brew --prefix node@22)/bin:$PATH"
```

Se necesita Terraform >= 1.10 y AWS CLI v2. Docker solo hace falta para
construir imagenes a mano; con el pipeline en marcha, no.

## 1.2 Perfil de AWS

```bash
aws configure --profile congenia

export AWS_PROFILE=congenia
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1

aws sts get-caller-identity
```

Confirmar visualmente la cuenta antes de seguir. El perfil necesita permisos
sobre VPC, ELB, ACM, ECS, ECR, IAM, RDS, ElastiCache, Secrets Manager,
CloudWatch, S3, Route 53 y Cloud Map. Estas variables viven en la terminal; no
van a `.env` ni a Git.

Para una cuenta nueva tambien se puede iniciar una sesion temporal desde el
navegador, sin reemplazar las credenciales de los perfiles anteriores:

```bash
aws login --profile congenia-new --region us-east-1
aws sts get-caller-identity --profile congenia-new
```

Si Terraform no reconoce las sesiones de `aws login`, usar el proveedor de
credenciales de la CLI:

```bash
aws configure set credential_process 'aws configure export-credentials --profile congenia-new --format process' --profile congenia-new-terraform
aws configure set region us-east-1 --profile congenia-new-terraform
export AWS_PROFILE=congenia-new-terraform
```

Referencia: [login con credenciales de consola](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html).

## 1.3 Bucket del estado remoto

Vive fuera de los dos stacks a proposito: es su backend, no puede
autodestruirse. Por eso **sobrevive a `make nuke`**: al reconstruir una cuenta
que ya lo tenia, este paso se comprueba en lugar de ejecutarse.

```bash
BACKEND_BUCKET="congenia-tfstate"

# Si ya existe, comprobar que conserve la configuracion y saltar a 1.4:
aws s3api get-bucket-versioning   --bucket "$BACKEND_BUCKET" --query Status
aws s3api get-bucket-encryption   --bucket "$BACKEND_BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm'
aws s3api get-public-access-block --bucket "$BACKEND_BUCKET" \
  --query 'PublicAccessBlockConfiguration.BlockPublicAcls'
```

Debe responder `Enabled`, `AES256` y `True`. Si es asi, seguir en 1.4.

Para crearlo desde cero:

```bash
BACKEND_BUCKET="congenia-tfstate"

aws s3api create-bucket --region us-east-1 --bucket "$BACKEND_BUCKET"

aws s3api put-bucket-versioning --bucket "$BACKEND_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block --bucket "$BACKEND_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket "$BACKEND_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
```

El versionado no es opcional: es lo unico que permite recuperar un estado
corrupto. Terraform usa locking nativo de S3; no hace falta DynamoDB.

En una cuenta independiente los nombres de S3 son globales, asi que hay que
acotarlos y reexportar el backend en cada terminal:

```bash
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export TF_CLI_ARGS_init="-reconfigure -backend-config=bucket=congenia-tfstate-${AWS_ACCOUNT_ID}"
export TF_VAR_state_bucket_name="congenia-tfstate-${AWS_ACCOUNT_ID}"
export TF_VAR_name_prefix="congenia-$(printf '%s' "$AWS_ACCOUNT_ID" | cut -c 7-12)"
export TF_VAR_domain_name="app.ejemplo.com"
```

## 1.4 Aplicar `envs/shared`

```bash
make init ENV=shared
terraform -chdir=envs/shared plan
make create ENV=shared
```

El plan debe crear seis repositorios ECR, el proveedor OIDC, los roles de
publicacion y despliegue, y una zona alojada.

En el primer despliegue de otra cuenta, mantener `enable_services=false`,
`enable_reporting=false` y `enable_cie10_schedule=false` mediante un archivo
de variables pasado despues de `features.tfvars`. Publicar las imagenes y
preparar la base antes de arrancar servicios. Si no se recupero la
`APP_ENCRYPTION_KEY` original, inicializar una base nueva: una clave nueva no
permite descifrar los pacientes del respaldo. Conservar el respaldo original
sin alteraciones para una recuperacion posterior.

El proveedor OIDC es unico por cuenta AWS. Si otro proyecto ya lo creo, el
apply falla con `EntityAlreadyExists` y se reutiliza el existente:

```bash
make create ENV=shared TF_VARS='-var=create_oidc_provider=false'
```

Guardar los tres valores que hacen falta despues:

```bash
terraform -chdir=envs/shared output ci_role_arn
terraform -chdir=envs/shared output ecr_registry
terraform -chdir=envs/shared output name_servers
```

## 1.5 Delegar el DNS a Route 53

El dominio sigue registrado en name.com; lo que se mueve es el hosting de DNS,
no la titularidad.

1. `output name_servers` imprime cuatro hostnames `ns-*.awsdns-*`.
2. En name.com: **My Domains** -> `cogenia.app` -> **Nameservers** ->
   reemplazar los cuatro por los de Route 53 -> guardar.
3. Esperar la propagacion (15 min a 2 h):

```bash
dig +short NS cogenia.app @1.1.1.1
```

No continuar hasta que respondan los nameservers de AWS. Hecho esto, Terraform
crea la validacion del certificado y el ALIAS al ALB por su cuenta, y el paso
manual de DNS desaparece de todos los despliegues siguientes.

Es el unico paso que no se automatiza: el registrador esta fuera de la cuenta
AWS y se hace una sola vez.

## 1.6 Configurar GitHub

En GitHub Free, configurar estas variables y secretos **en cada repositorio
privado**, porque los valores de organizacion no estan disponibles para ellos.
No hace falta hacer publicos los servicios; el workflow reutilizable puede
seguir publicado en `CONGENIA-INFRA`.

**Variables de repositorio** — *Settings -> Secrets and variables -> Actions
-> Variables*, en `CONGENIA-M1`, `CONGENIA-M1-SERVER`,
`CONGENIA-M1-PDF-WORKER`, `CONGENIA-CIE10` y `CONGENIA-ORCH`:

| Variable | Valor |
|---|---|
| `AWS_ROLE_ARN` | salida `ci_role_arn` de 1.4 |
| `AWS_REGION` | `us-east-1` |
| `ECR_REGISTRY` | salida `ecr_registry` de 1.4 |

Van como variables y no escritas en los workflows para que cambiar de cuenta
AWS sea editar tres campos y no cinco archivos.

**Despliegue manual en INFRA** — `deploy-production.yml` usa el
`GITHUB_TOKEN` automatico de su propio repositorio (`contents: write`), y el rol
OIDC separado `congenia-gha-deploy` para AWS. No hay PAT, secreto compartido entre
repositorios ni GitHub App que configurar. Los publicadores solo escriben en ECR.

El rol de despliegue se declara en `envs/shared/deploy.tf`; aplicar ese stack una
vez y consultar `terraform -chdir=envs/shared output -raw deploy_role_arn`.
Guardar ese ARN como variable `AWS_DEPLOY_ROLE_ARN` en INFRA. El workflow
comprueba la cuenta y requiere estas variables de repositorio antes de
autenticarse o inicializar Terraform:

| Variable en CONGENIA-INFRA | Valor de la cuenta nueva |
|---|---|
| `AWS_ACCOUNT_ID` | `789165946497` |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::789165946497:role/congenia-946497-gha-deploy` |
| `AWS_REGION` | `us-east-1` |
| `TF_STATE_BUCKET` | `congenia-tfstate-789165946497` |
| `TF_NAME_PREFIX` | `congenia-946497` |
| `TF_DOMAIN_NAME` | `cogenia.app` |

Configurar en **Settings -> Secrets and variables -> Actions -> Variables**.
Son identificadores publicos de configuracion; la autenticacion AWS utiliza
OIDC y las credenciales temporales se obtienen en cada ejecucion.
`scripts/ci-context.py` prepara el backend con `allowed_account_ids`, y exporta
las variables Terraform de region, prefijo y dominio. La identidad recibida y
el propietario del bucket se comprueban antes de planificar.

En cada publicador de la tabla anterior, el rol es
`arn:aws:iam::789165946497:role/congenia-946497-gha-ecr-push` y el registry es
`789165946497.dkr.ecr.us-east-1.amazonaws.com`. La region es `us-east-1`.
El subject de despliegue esta restringido a la identidad inmutable de
`CONGENIA-INFRA` y la rama `master`.

Publicar los cambios de INFRA en `master` antes de ejecutar el workflow con
estas variables. Como primera comprobacion, ejecutar `publish-image` de
PDF-WORKER sobre `main`, y despues `deploy-production` de INFRA con
`service=pdf-worker`, `latest=true` y `preview_only=true`. El preview revisa la
imagen publicada y el plan sin aplicar cambios. Reutilizar el JSON
`resolved_tags` del preview para fijar exactamente esa seleccion al desplegar.

El workflow necesita poder escribir directamente en `master`. Si se agregan
reglas de proteccion que lo impidan, habra que configurar un actor autorizado
para ese bypass; no habilitar merges automaticos como sustituto del despliegue.
Una GitHub App es una opcion si en el futuro se requiere acceso entre repos.

Tras verificar el nuevo flujo, eliminar los secretos `INFRA_TOKEN` de los cinco
repositorios y revocar el PAT anterior en la cuenta de su titular. Ya no se
consume en ningun workflow. AWS sigue usando OIDC, sin access keys permanentes.

## 1.7 Comprobar el OIDC y poblar ECR

Probar primero el repositorio mas simple: en `CONGENIA-M1-PDF-WORKER`, pestana
**Actions** -> `publish-image` -> **Run workflow**. Debe publicar
`congenia/pdf-worker:<version>-<sha>`.

```bash
aws ecr describe-images --repository-name congenia/pdf-worker \
  --query 'imageDetails[].imageTags' --output table
```

Si falla en `configure-aws-credentials` con `AccessDenied`, el sujeto OIDC no
coincide con la identidad emitida: revisar `var.ci_subjects` en `envs/shared`.
GitHub puede emitir un subject con IDs inmutables. Para CIE10 la condicion es:

```text
repo:CONGENIAGT@271886543/CONGENIA-CIE10@1317646820:ref:refs/heads/main
```

El paso de diagnostico del workflow muestra `role`, `subject` y `audience` sin
exponer el token. Compara esos campos con la confianza del rol; conserva la rama
exacta, sin ampliar a comodines. Despues de corregir `envs/shared`, aplica ese
stack y vuelve a ejecutar el workflow. Los publicadores ya no usan
`INFRA_TOKEN` ni acceden a INFRA.
Consulta la [referencia OIDC de GitHub](https://docs.github.com/en/actions/reference/security/oidc).

Repetir para todos los artefactos: `publish-image` en `CONGENIA-M1`,
`CONGENIA-M1-SERVER`, `CONGENIA-M1-PDF-WORKER` y `CONGENIA-CIE10`,
`publish-migrate` en `CONGENIA-M1-SERVER`, y `publish-keycloak` en
`CONGENIA-ORCH`. El resumen de cada ejecucion muestra el tag publicado.
En un entorno ya levantado, elegir ese tag desde `deploy-production` (2.8).
Para el primer arranque, registrar los tags en `envs/aws/images.tfvars` antes
de crear los servicios.

> `workflow_dispatch` solo aparece en la interfaz si el archivo del workflow
> existe en la rama por defecto. En una rama de trabajo hay que disparar por
> push.

## 1.8 Si la cuenta ya estaba desplegada

Los cinco repositorios ECR existen y estan en el estado de `envs/aws`. Al
sacarlos de la configuracion, `plan` los da por eliminados, y un `destroy`
tampoco funciona sobre ellos: `force_delete` es un campo que solo existe en
Terraform y el provider lo lee del **estado**, donde quedo en `false`, asi que
ECR rechaza borrar repositorios con imagenes.

Hay que moverlos de estado antes de tocar nada:

```bash
./scripts/migrate-ecr-state.sh            # simula
./scripts/migrate-ecr-state.sh --aplicar
```

El script se niega a soltar nada de `envs/aws` si el import no quedo completo,
y al terminar comprueba que el plan ya no proponga destruir repositorios.

Despues, o bien se sigue trabajando (`make create ENV=shared` y continuar en
1.5), o se tira todo para reconstruir con esta receta:

```bash
make nuke CONFIRM_DESTROY=destroy-congenia-todo
./scripts/verify-teardown.sh              # debe salir limpio
```

Cuando el barrido salga limpio, empezar desde 1.1. **No saltarse la
comprobacion**: un stack a medio destruir es peor punto de partida que uno
intacto, porque el estado y la realidad dejan de coincidir. Del perimetro, en
una reconstruccion solo interesa conservar el bucket del estado remoto.

> Mientras la zona de Route 53 no exista, `envs/aws` se aplica con
> `-var=manage_dns=false`: el default `true` haria fallar el plan por no
> encontrarla. `make destroy` ya lo pasa por su cuenta.

---

# Parte 2 — Desplegar

## 2.1 Preparar la terminal

```bash
export AWS_PROFILE=congenia
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1

aws sts get-caller-identity
make cost-status
```

En una cuenta independiente, reexportar tambien `TF_CLI_ARGS_init`,
`TF_VAR_state_bucket_name`, `TF_VAR_name_prefix` y `TF_VAR_domain_name` de 1.3.

## 2.2 Revisar el plan

```bash
make plan ENV=aws
```

Comprobar que no haya destrucciones inesperadas, que RDS y Redis usen clases
micro, que RDS sea Single-AZ con un dia de retencion, que cada servicio tenga
como maximo una tarea, y que `data.aws_ecr_repository` resuelva los cinco
repositorios.

## 2.3 Levantar

```bash
make up-aws ENV=aws
```

Un comando encadena `create` (red, NAT, ALB, RDS, Redis, S3, secretos, ECS,
certificado y DNS), `migrate` (esquema), `open` (una tarea por servicio) y
`smoke` (enrutamiento a traves del ALB).

Detalles que importan mientras corre:

- **El certificado se emite solo.** Terraform escribe el registro de validacion
  y espera el `ISSUED`. Tarda entre dos y diez minutos; el apply parece
  detenido y no lo esta.
- **La migracion debe terminar con codigo 0.** Es idempotente: si el esquema ya
  esta cargado, lo detecta y no hace nada.
- **Keycloak tarda.** Tiene 300 segundos de gracia antes de que ECS evalue los
  health checks del ALB.

Por partes, si se prefiere:

```bash
make create ENV=aws     # base, con los servicios apagados
make migrate ENV=aws    # esquema
make open ENV=aws       # arranca las tareas
make smoke ENV=aws      # pruebas
```

Un `503` entre `create` y `open` es normal: los servicios estan en cero.

## 2.4 Configurar Keycloak

Idempotente. Verifica y repara los scopes OIDC estandar, el cliente web PKCE,
los roles `medico`/`congenia-admin`, el mapper firmado `tenants` y el usuario
inicial. Requiere Python 3 (biblioteca estandar). Las peticiones administrativas
comparten un cache temporal privado, renuevan antes de expirar y reintentan
una vez si Keycloak rechaza el token con 401;
el token no se imprime ni se pasa como argumento de proceso.

El backend usa `tenants` desde el access token como autoridad para
filtrar fichas y adendas; sin ese atributo el usuario no ve datos clinicos.

```bash
export KEYCLOAK_BASE_URL="$(terraform -chdir=envs/aws output -raw public_url)"

export KEYCLOAK_ADMIN_PASSWORD="$(aws secretsmanager get-secret-value \
  --region us-east-1 \
  --secret-id "$(terraform -chdir=envs/aws output -raw keycloak_admin_secret_arn)" \
  --query SecretString --output text)"

export KEYCLOAK_MEDICO_PASSWORD="$(aws secretsmanager get-secret-value \
  --region us-east-1 \
  --secret-id "$(terraform -chdir=envs/aws output -raw keycloak_medico_initial_secret_arn)" \
  --query SecretString --output text)"

# Defaults productivos. El medico recibe membresias por tenant; el usuario
# administrativo recibe el grupo de superadministradores.
export KEYCLOAK_MEDICO_TENANTS="${KEYCLOAK_MEDICO_TENANTS:-23,254}"
export KEYCLOAK_SUPERADMIN_USERNAME="${KEYCLOAK_SUPERADMIN_USERNAME:-admin-doctor}"
export KEYCLOAK_SADC_TENANT="${KEYCLOAK_SADC_TENANT:-254}"

./scripts/configure-keycloak-web.sh

unset KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_MEDICO_PASSWORD KEYCLOAK_MEDICO_TENANTS KEYCLOAK_SUPERADMIN_USERNAME KEYCLOAK_SADC_TENANT
```

El script agrega al cliente `congenia-web` el mapper `groups` (rutas de grupo
completas en el access token, p. ej. `/instituciones/254/medicos`). La API calcula
los permisos por institución con ese claim y `config/access-policy.yaml`: un token
sin `groups` no tiene permisos. **Este script debe correrse antes de desplegar una
versión de la API que use permisos por institución**; si la API llega primero,
ningún usuario podrá operar hasta que el mapper exista y los usuarios renueven su
token (máximo la duración del access token).

Exigir el mensaje final:

```text
OK: congenia-web verificado con scopes profile, email, roles y tenants; usuario medico.inicial configurado.
```

## 2.5 Probar

```bash
make smoke ENV=aws

export SADC_CLIENT_SECRET="$(aws secretsmanager get-secret-value \
  --region us-east-1 \
  --secret-id "$(terraform -chdir=envs/aws output -raw sadc_client_secret_arn)" \
  --query SecretString --output text)"

make smoke-integration ENV=aws
unset SADC_CLIENT_SECRET
```

Estado de ECS:

```bash
ECS_CLUSTER="$(terraform -chdir=envs/aws output -raw ecs_cluster)"
SERVICE_PREFIX="${TF_VAR_name_prefix:-congenia}-prod"

aws ecs describe-services \
  --region us-east-1 --cluster "$ECS_CLUSTER" \
  --services "${SERVICE_PREFIX}-api" "${SERVICE_PREFIX}-frontend" \
             "${SERVICE_PREFIX}-keycloak" "${SERVICE_PREFIX}-rabbitmq" \
             "${SERVICE_PREFIX}-pdf-worker" \
  --query 'services[*].[serviceName,desiredCount,runningCount,pendingCount]' \
  --output table
```

Cada servicio debe mostrar `desired=1`, `running=1`, `pending=0`.

```bash
open "$(terraform -chdir=envs/aws output -raw public_url)"
```

El usuario inicial es `medico.inicial`, con password temporal en el secreto
`keycloak_medico_initial_secret_arn`; hay que cambiarla al primer login.

## 2.6 Validar CIE-10

La tarea manual CIE-10 **no** es la revision del medico en el dashboard. Es una
corrida a demanda del mismo batch que EventBridge ejecuta al final de mes:
lee los snapshots CSV desde S3, llama a OpenAI, llena las tablas `cie10_*` y
deja la cola lista para `/dashboard/cie10`.

Primero cargar los snapshots productivos:

```bash
DOCS_BUCKET="$(terraform -chdir=envs/aws output -raw docs_bucket)"

aws s3 cp CIE10.csv "s3://${DOCS_BUCKET}/cie10/input/CIE10.csv"
aws s3 cp CIE10_Traductor.csv "s3://${DOCS_BUCKET}/cie10/input/CIE10_Traductor.csv"
aws s3 cp verasativa-cie-10.csv "s3://${DOCS_BUCKET}/cie10/input/verasativa-cie-10.csv"
```

El archivo de referencia se obtiene del commit fijado
`8e22d45e932badbc344f81e18e677a655ab3bc3a` de `verasativa/CIE-10`. Antes de
usarlo en produccion, verificar el SHA-256
`c3963d12c44706be2bc629c2beb401cd249a51db45cc24a4e22198f771824765` y conservarlo para
reconstruir exactamente el corpus. El catalogo institucional sigue siendo la
fuente local prioritaria; la referencia amplia el contexto y no autoriza una
decision clinica por si sola.

Luego cargar manualmente el secreto de OpenAI. El valor no se pasa por
Terraform para evitar que viaje por tfvars o quede acoplado al flujo de plan:

```bash
aws secretsmanager put-secret-value \
  --region us-east-1 \
  --secret-id "$(terraform -chdir=envs/aws output -raw cie10_openai_secret_arn)" \
  --secret-string "$OPENAI_API_KEY"
```

Aplicar primero la migracion del backend y construir una version activa del
indice. El indexador valida duplicados, padres, ciclos y ancestros, combina
ambos catalogos, genera embeddings y escribe la version en S3 Vectors. Tambien
migra idempotentemente el indice a modo `ENHANCED` antes de ingerir:

```bash
make migrate ENV=aws
make cie10-index ENV=aws
```

El batch se niega a procesar registros si no existe una version RAG activa.
Esto evita mezclar una corrida con un indice incompleto. Tras indexar, ejecutar
el batch a demanda antes de esperar al scheduler mensual:

```bash
make cie10-batch ENV=aws
```

El script lanza la task Fargate `cie10`, espera a que termine, imprime los logs
de `/ecs/congenia-prod/cie10` y falla si el contenedor termina con exit code
distinto de cero. Despues de una corrida verde:

1. Entrar con un usuario `congenia-admin`.
2. Abrir `/dashboard/cie10`.
3. Aceptar o corregir cada fila; los codigos externos requieren confirmacion
   explicita del revisor.
4. Aceptar la clausula versionada y confirmar el lote completo.

La confirmacion ya no genera un CSV nuevo. Los endpoints de exportacion previos
se conservan temporalmente solo para archivos historicos. Sin override, la task
asigna el mes calendario anterior en `America/Guatemala`; para un backfill se
puede sobrescribir `CIE10_BATCH_PERIOD=YYYY-MM` al ejecutar la task manual.

Cada actualizacion del catalogo o del modelo de embeddings requiere una nueva
version `cie10_rag_version` en `envs/aws/features.tfvars` y una corrida de
`make cie10-index ENV=aws` antes
del siguiente batch. No se elimina la version anterior: queda archivada para
trazabilidad de las sugerencias ya generadas.

Produccion usa unicamente `CIE10_EMBEDDING_PROVIDER=openai`, modelo
`text-embedding-3-small`, 512 dimensiones y cosine. Las tareas CIE10 no inyectan
configuracion de Titan ni reciben permisos de Bedrock. El soporte opcional de
Titan en el codigo queda fuera del entorno desplegado y de estas pruebas; no
requiere solicitar cuotas ni ejecutar tareas adicionales para continuar con OpenAI.

El batch solo lee los snapshots de `cie10/input/` y consulta vectores con sus
metadatos. El indexador solo lee esos snapshots, escribe vectores y configura el
modo del indice. Ninguna de las dos tareas escribe exportaciones S3; las rutas
historicas de exportacion siguen perteneciendo a la API. Ambas tareas necesitan
unicamente la clave OpenAI y la credencial PostgreSQL de `congenia_app` como secretos.

Para evaluar OpenAI sin cambiar el puntero RAG activo, ejecutar el indexador con
una version `eval-...` nueva y `CIE10_ACTIVATE_RAG=false`. La version terminada
queda `READY`. El indexador tambien actualiza el catalogo SQL compartido y el modo
del indice vectorial; usar los mismos snapshots institucionales de produccion.
`make cie10-index` activa el indice OpenAI por defecto y se reserva para la
preparacion productiva deliberada, despues de las pruebas.

El scheduler sigue el valor versionado de `enable_cie10_schedule`. Antes de
habilitarlo, validar la corrida manual, revisar `make plan ENV=aws` y aplicar.
Repetira la corrida con `cron(0 6 L * ? *)` en `America/Guatemala`.

## 2.7 Validar reportería y agente

`CONGENIA-REPORTING-PIPELINE` no se despliega en ECS ni publica imagen. Es una
herramienta operativa para preparar el dataset SIGSA desidentificado e importarlo
a un PostgreSQL externo.

Antes de abrir `/dashboard/reporteria`, cargar los secretos que consumirá la API:

```bash
aws secretsmanager put-secret-value \
  --region us-east-1 \
  --secret-id "$(terraform -chdir=envs/aws output -raw reporting_database_app_url_secret_arn)" \
  --secret-string "$REPORTING_DATABASE_APP_URL"

aws secretsmanager put-secret-value \
  --region us-east-1 \
  --secret-id "$(terraform -chdir=envs/aws output -raw reporting_database_agent_readonly_url_secret_arn)" \
  --secret-string "$REPORTING_DATABASE_AGENT_READONLY_URL"

aws secretsmanager put-secret-value \
  --region us-east-1 \
  --secret-id "$(terraform -chdir=envs/aws output -raw reporting_llm_api_key_secret_arn)" \
  --secret-string "$LLM_API_KEY"

aws secretsmanager put-secret-value \
  --region us-east-1 \
  --secret-id "$(terraform -chdir=envs/aws output -raw reporting_mcp_token_secret_arn)" \
  --secret-string "$REPORTING_MCP_TOKEN"
```

Ejecutar `make reporting-ready ENV=aws` y validar que las dos URLs conectan a la
base externa, que el agente usa un usuario readonly y que el dataset esta
importado. Luego versionar `enable_reporting = true` en
`envs/aws/features.tfvars` y aplicar con `make plan` / `make open`. Hasta entonces,
la API no inyecta esos secretos y las consultas que requieren la base externa
responden que reporteria no esta configurada.

Luego, desde `CONGENIA-REPORTING-PIPELINE`, ejecutar:

```bash
pnpm anonymize:sigsa -- --input /ruta/segura/SIGSA3Migrado_Puro.csv \
  --output output/sigsa_desidentified.csv --manifest output/manifest.json \
  --dataset-version sigsa-YYYYMMDD
pnpm validate:sigsa -- --input output/sigsa_desidentified.csv
REPORTING_DATABASE_ADMIN_URL="$REPORTING_DATABASE_ADMIN_URL" \
  pnpm import:sigsa -- --input output/sigsa_desidentified.csv --manifest output/manifest.json
```

El CSV original no se sube a AWS ni se versiona. Solo se importa el CSV
desidentificado.

## 2.8 Publicar y desplegar una version nueva

1. Publicar el cambio en `main` (o `master` en ORCH). Su workflow ejecuta las
   verificaciones y publica la imagen inmutable en ECR. No abre PR en INFRA.
2. Esperar a que la publicacion termine correctamente. El tag aparece en su
   resumen. No es necesario copiarlo si se usa la nueva opcion `latest`.
   Para consultar tags manualmente:

```bash
aws ecr describe-images --region us-east-1 --repository-name congenia/api \
  --query 'sort_by(imageDetails,&imagePushedAt)[].imageTags' --output json
```

3. Abrir **CONGENIA-INFRA -> Actions -> deploy-production -> Run workflow**,
   seleccionar la rama **master** y elegir una modalidad:

| Modalidad | service | components | latest | tag / resolved_tags |
|---|---|---|---|---|
| Ultima imagen de un componente | `frontend` (o api/pdf-worker/keycloak/cie10) | vacio | marcado | ambos vacios |
| Ultimas imagenes de varios componentes | `selected` | `frontend,pdf-worker` (ejemplo) | marcado | ambos vacios |
| Ultimas imagenes de los cinco componentes | `selected` | `all` | marcado | ambos vacios |
| Version exacta de un componente / rollback | servicio individual | vacio | desmarcado | tag exacto en `tag` |
| Versiones exactas de varios componentes | `selected` | lista de componentes | desmarcado | JSON en `resolved_tags` |
| Subconjunto de versiones ya registradas | `selected` | lista de componentes o `all` | desmarcado | ambos vacios |
| Manifiesto completo, incluida su migracion | `manifest` | vacio | desmarcado | ambos vacios |

   Los nombres validos para `components` son `api`, `frontend`, `pdf-worker`,
   `keycloak` y `cie10`, separados por comas; `all` selecciona esos cinco.
   No admite `migrate`, RabbitMQ ni nombres repetidos. GitHub no tiene un
   selector nativo multiple para este input: se escribe la lista.
4. Si la API incluye SQL nuevo, rellenar tambien `migrate_tag` con su imagen
   `schema-...` compatible con la API elegida. Tambien funciona con
   `service=selected` si `components` incluye `api`. El workflow comprueba el plan completo, registra primero esa
   definicion, ejecuta las migraciones incrementales y exige exit code 0 antes
   de actualizar la API. Si falla SQL, la API mantiene su revision anterior.
   La base puede haber aplicado archivos anteriores de esa corrida; no se
   revierten datos automaticamente. Tambien se puede elegir `service=migrate`
   para ejecutar solo la migracion.
   **`latest` y `components=all` nunca eligen ni ejecutan migraciones por su
   cuenta.** Sin `migrate_tag`, una seleccion de API no ejecuta SQL. El runner
   no detecta si esa API necesita un esquema nuevo: hay que revisar sus cambios
   SQL. No relaciona tags por SHA ni asume que la ultima migracion es compatible.
   `service=migrate` exige un `tag` exacto; no admite `latest`.
5. `service=manifest` despliega juntos los seis tags ya registrados en
   `images.tfvars`, ejecutando primero la migracion incluida; dejar `tag` y
   `migrate_tag` vacios. Sirve para sincronizar cambios de varios componentes
   que ya estan versionados. Cada tag se verifica contra ECR.
6. `runtime_config=true` incluye tambien cambios de variables de ejecucion
   (`environment`) de los servicios elegidos. Sigue rechazando cambios de roles,
   secretos inyectados, puertos, volumenes, CPU/memoria y red. Si hay cambios
   pendientes en otros servicios, elegir `manifest` o resolverlos por separado;
   una release individual nunca los aplica de forma incidental.
7. `preview_only=true` permite revisar los cambios sin aplicarlos. Para desplegar,
   dejarlo desmarcado. La ejecucion es manual; publicar una imagen no despliega.

### Ejemplo: actualizar frontend y PDF sin conocer sus tags

1. Abrir el workflow en `master`, elegir `service=selected` y escribir
   `components=frontend,pdf-worker`.
2. Marcar `latest` y `preview_only`. Dejar `tag`, `resolved_tags` y
   `migrate_tag` vacios. Dejar `runtime_config` desmarcado si solo cambian imagenes.
3. Ejecutar y esperar a que termine en verde. El resumen muestra las imagenes
   de las definiciones activas de ECS (para CIE10, el target del scheduler),
   las seleccionadas, cuales cambian y un JSON para `resolved_tags`.
   Una imagen igual no fuerza un reinicio; Terraform tambien comprueba
   revisiones y configuracion, por lo que un mismo tag puede requerir otro
   cambio permitido si se marco `runtime_config` o se corrige una revision.
4. Copiar el JSON completo del resumen. Por ejemplo, el formato es:

```json
{"frontend":"1.0.0-abcdef0","pdf-worker":"1.0.0-1234567"}
```

5. Iniciar **otra ejecucion nueva**, misma rama, servicio y componentes:
   **desmarcar `latest`**, pegar el JSON en `resolved_tags` y **desmarcar
   `preview_only`**. Mantener el mismo `runtime_config` y, si se incluyo API
   con SQL, el mismo `migrate_tag` explicito. Los valores de ejemplo no son
   tags reales: copiar los del resumen propio.
6. Esperar estabilidad, smoke HTTPS y registro del manifiesto. El workflow
   confirma directamente los tags desplegados en `images.tfvars`, sin PR.

El JSON debe contener exactamente los componentes elegidos, con tags que
existan en ECR. No incluye migraciones; estas siguen en `migrate_tag`.
Tambien sirve para un componente individual, dejando `tag` vacio.
`resolved_tags` no se combina con `latest`, `tag`, `manifest` ni `migrate`.

### Que significa ultima imagen

Se consultan todas las paginas de ECR y se elige por `imagePushedAt`, no por
orden alfabetico, version numerica ni orden del SHA. Se consideran solo tags
con el formato de los publicadores (`version-sha`, por ejemplo
`1.0.0-abcdef0` o `26.6.1-abcdef0`); se ignoran imagenes sin tag y aliases
como `latest`/`dev`. Si no existe una imagen valida o hay varias candidatas
empatadas en la ultima fecha, la ejecucion falla antes del plan y pide una
version exacta. La consulta usa la paginacion automatica de
[ECR DescribeImages](https://docs.aws.amazon.com/cli/latest/reference/ecr/describe-images.html).

La seleccion se fija una vez al iniciar cada ejecucion: no vuelve a buscar
tags durante el apply. **Dos ejecuciones con `latest` pueden elegir versiones
distintas** si se publica otra imagen entre ellas; usar `resolved_tags` para
aplicar exactamente las imagenes revisadas. La configuracion Terraform sigue
siendo la del commit de INFRA seleccionado al iniciar cada ejecucion; si ese
codigo cambia entre preview y apply, revisar un preview nuevo.
Ultima publicada no significa necesariamente ultimo commit de la rama: si
el publicador aun no termina o falla, esa imagen no esta disponible.

El runner resuelve y valida todas las imagenes antes de planear, conserva
`enable_services=true`, rechaza cambios fuera de los componentes solicitados y permite solamente cambios de imagen,
revision ECS y revision del target CIE10; las variables de ejecucion requieren
`runtime_config=true`. No aplica cambios de red, RDS, secretos,
roles, escala ni calendario. La infraestructura estructural se actualiza por
separado. El rol AWS tiene escrituras acotadas a ECS, el target CIE10 y el estado
Terraform de la aplicacion; no tiene permisos para destruir RDS/S3 ni editar IAM.

Despues espera la revision exacta de ECS y ejecuta el smoke HTTPS. Solo entonces
registra `images.tfvars` directamente en `master` con `GITHUB_TOKEN`, sin PR.
El registro usa `scripts/record-release.py` en un worktree temporal limpio:
solo confirma los tags de un JSON que el deploy escribe despues de verificar
ECS y el smoke. No contiene credenciales ni se publica como artifact.
Los archivos modificados por Terraform u otras herramientas en el runner no se incluyen en el commit
ni impiden el registro. Conserva cambios concurrentes de otros componentes;
si otro commit cambio el mismo componente a un tercer tag, se detiene para
revisar. El push nunca se fuerza.
Si falla la salud, la ejecucion queda roja y el manifiesto no se confirma; AWS
puede haber avanzado parcialmente. Consultar ECS antes de repetir. Para volver a
una imagen anterior, ejecutar el mismo workflow con su tag publicado; esto no
revierte el esquema PostgreSQL. Si hay un conflicto al guardar el manifiesto,
resolverlo con las revisiones realmente desplegadas; no se fuerza el push.

Si falla solamente **Registrar release verificada sin PR**, el despliegue y
el smoke ya pueden haber terminado correctamente. Comprobar las imagenes y
la estabilidad de ECS antes de repetir; no interpretar el job rojo como un
rollback. Recuperar el registro con los tags realmente verificados y usar una
ejecucion nueva sobre el workflow corregido si hace falta volver a comprobarlo.
**Re-run jobs** de una ejecucion antigua conserva su commit y su codigo.

La configuracion se toma del commit seleccionado al iniciar el workflow, y
los providers estan fijados con los lockfiles versionados por entorno.
Las releases se serializan con un unico grupo de concurrencia; no se cancela
una ejecucion activa por iniciar otra. No se publican planes ni tfstate como
artifacts, porque contienen secretos. Para CIE10 se actualiza su definicion y
calendario, sin procesar registros en ese momento; probarlo con
`make cie10-batch ENV=aws` cuando corresponda.

La via local sigue disponible:

```bash
git pull
export TF_VAR_enable_services=true
make plan ENV=aws
make open ENV=aws
make smoke ENV=aws
```

## 2.8 Acceso a RDS desde DBeaver

El stack `envs/db-access` crea una EC2 `t4g.micro` privada con SSM, disco gp3
cifrado de 8 GiB, IAM y una regla TCP 5432. Usa el NAT existente. El documento
SSM fija el endpoint de RDS; solo se puede elegir el puerto local. Los recursos
llevan `Project=CONGENIA`, `Component=db-access`, `Environment=prod` y nombre
`congenia-prod-db-access`. El estado usa `congenia/db-access/terraform.tfstate`
en el mismo backend S3; los comandos nunca aplican el stack principal.

**Preparación única sobre una VPC existente.** Renovar primero las credenciales
AWS y conservar las variables del entorno vigente (dominio, prefijo y opciones).
Para una plataforma actualmente encendida:

```bash
export AWS_PROFILE=congenia
export AWS_REGION=us-east-1
aws sts get-caller-identity
export TF_VAR_enable_services=true
make db-access-prepare ENV=aws
make plan ENV=aws
# Solo después de revisar el plan:
make apply ENV=aws
```

`db-access-prepare` importa las tres reglas existentes del SG `data` a recursos
individuales de Terraform: no modifica tráfico ni recrea el grupo. Puede
reintentarse; si una regla falta o es ambigua, se detiene. Para ver únicamente
los IDs antes de importar: `./scripts/migrate-data-sg-rules.sh envs/aws`.
El plan debe conservar RDS, VPC y servicios, sin revocar accesos; publicar el
output `db_access_context` permite crear el acceso. En instalaciones nuevas las
reglas nacen directamente y no requieren importación. **No usar un apply con
las opciones por defecto sobre una plataforma encendida**: `enable_services`
vale false por defecto. Tampoco usar `-target` para el funcionamiento habitual.

**Uso desde Mac.** Instalar el [Session Manager plugin para macOS](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-macos-overview.html)
y comprobar `session-manager-plugin --version`. Después:

```bash
make db-access-plan
make db-access-up           # crea o enciende; espera SSM Online
make db-access-status
make db-access-tunnel       # dejar la terminal abierta
# Puerto alternativo: DB_ACCESS_LOCAL_PORT=15433 make db-access-tunnel
```

En DBeaver: PostgreSQL, host `127.0.0.1`, puerto `15432`, base `congenia`,
credenciales PostgreSQL y túnel SSH desactivado. En SSL usar `sslmode=verify-ca`
y la CA de [RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)
en `sslrootcert` (por ejemplo `global-bundle.pem`). `verify-ca` comprueba la CA;
`verify-full` exige además conservar el hostname real de RDS en la conexión,
que no coincide con localhost. Los usuarios de Keycloak no autentican contra
PostgreSQL. Para consultas, usar un usuario SQL de solo lectura ya provisionado;
este componente no crea usuarios ni modifica el esquema.

El contrato sin contraseñas se guarda automáticamente en
`envs/db-access/connection.auto.tfvars.json` (ignorado por Git). No editar su
destino mientras el acceso exista. Se conserva si falla la limpieza y se borra
cuando AWS confirma la eliminación. Para otra cuenta se hereda la configuración
del backend de 1.3. `DB_ACCESS_CORE_DIR` permite usar otro directorio principal.
Una recreación de la VPC requiere destruir primero el acceso anterior.

El administrador puede asignar la política operadora a identidades IAM
existentes mediante `operator_role_names` / `operator_user_names` en
`envs/db-access/operators.auto.tfvars`; por ejemplo:
`operator_role_names = ["operador-db"]`. Terraform retira esas asignaciones al
destruir. No adjuntar la política manualmente: una asignación externa bloquearía
su eliminación. Una identidad que ya tenga permisos suficientes puede usarla
sin asignaciones nuevas. La política operadora permite túnel, consultas de
estado y start/stop; crear/destruir sigue requiriendo permisos de infraestructura
y acceso al backend. `db-access-up` también ejecuta Terraform; para un operador
sin esos permisos, el administrador provisiona y el operador enciende desde EC2
(o `aws ec2 start-instances --instance-ids <id>`) antes de abrir el túnel.

**Apagado y eliminación.** Ctrl-C cierra el túnel pero deja la máquina encendida:

```bash
make db-access-stop
make db-access-destroy CONFIRM_DESTROY=destroy-congenia-db-access
make db-access-verify
```

`stop` espera hasta `stopped`: cesa el cómputo, permanece EBS. `destroy` elimina
EC2, su disco, SG, reglas, IAM/asignaciones y documento SSM, y verifica contra AWS.
La auditoría detecta también snapshots etiquetados y recursos parciales; no borra
manualmente recursos ajenos al estado. Si falla, reporta IDs y conserva el
contrato para diagnosticar/reintentar. `status` y `verify` son consultas y no
encienden recursos. Session Manager para EC2 no tiene cargo adicional; NAT/RDS
conservan su coste. El backend de Terraform también permanece.

Validación local sin AWS: `make test-db-access` y, tras inicializar el módulo,
`terraform -chdir=modules/db-access test`. Son pruebas simuladas; la aceptación
real requiere conectar DBeaver, detener/encender y destruir/verificar en AWS.

---

# Parte 3 — Apagar

## 3.1 Dormir los servicios

```bash
make close ENV=aws
```

Lleva Fargate a cero y detiene db-access si existe, sin borrar datos ni red.
`make stop` es un alias de `close`; EBS del acceso permanece. NAT, ALB, RDS y Redis siguen
cobrando. Para una pausa de horas.

## 3.2 Destruir el entorno

```bash
make destroy ENV=aws CONFIRM_DESTROY=destroy-congenia-aws
make cost-status
```

Primero elimina y verifica db-access; si falla, no sigue con la VPC.
Elimina todo el gasto significativo: NAT, ALB, RDS sin snapshot final, Redis,
Fargate, secretos y el bucket de documentos. **Conserva imagenes, DNS e
identidad de CI**, asi que volver es `make up-aws` sin republicar nada ni tocar
DNS.

Es el habito recomendado para una pausa larga. Los datos se pierden.

## 3.3 Nuke total

```bash
make nuke CONFIRM_DESTROY=destroy-congenia-todo
```

Destruye primero `envs/db-access`, luego `envs/aws` y **despues** `envs/shared` —el orden es obligatorio,
porque `envs/aws` lee los repositorios ECR desde el otro stack—. Borra tambien
las imagenes, la zona DNS y el rol de CI.

No existe para ahorrar: el stack compartido cuesta menos de un dolar al mes.
Existe para que cerrar el proyecto no deje recursos ni credenciales huerfanas.
Volver exige rehacer la parte 1 completa, incluida la re-delegacion de
nameservers.

Ejecutado sin la confirmacion, solo imprime que haria.

Al terminar corre `scripts/verify-teardown.sh`, que le pregunta a AWS que
sobrevivio en lugar de confiar en que Terraform termino en verde, y el
checklist de lo que vive fuera de Terraform: el bucket del estado remoto, la
delegacion en name.com y las variables de GitHub.

```bash
make verify-teardown                        # auditar en cualquier momento
./scripts/verify-teardown.sh --perimetro    # lo que ningun destroy alcanza
```

Limpiar la terminal:

```bash
unset TF_VAR_enable_services TF_VAR_domain_name TF_VAR_name_prefix
unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION
unset ECS_CLUSTER SERVICE_PREFIX
```

---

## Errores frecuentes

**`plan` dice que no encuentra un repositorio ECR.** `envs/shared` no esta
aplicado en esta cuenta: ir a 1.4.

**El frontend responde 503.** Los servicios estan en cero. Falta
`make open ENV=aws`; `make create` usa `enable_services=false` por defecto y
eso es correcto durante el arranque.

**El apply se queda esperando el certificado.** Es lo esperado los primeros
minutos. Si pasa de diez, comprobar la delegacion con
`dig +short NS cogenia.app @1.1.1.1`.

**Una actualizacion intenta apagar ECS.** Falta
`export TF_VAR_enable_services=true`.

**ECR rechaza un tag existente.** No repetir el push. Con tags inmutables, si
el codigo cambio lo que falta es un commit nuevo: el tag se deriva del commit.

**El pipeline publica pero produccion no cambia.** Es el comportamiento
esperado: falta ejecutar `deploy-production` con el tag publicado. Si no aparece
el boton, comprobar que el workflow existe en `master` y que Actions esta
habilitado. Si falla al guardar el manifiesto, comprobar permisos de escritura
y reglas de la rama; el resultado del despliegue se ve en ECS y en el resumen.

**Keycloak devuelve `invalid_scope`.** Ejecutar
`scripts/configure-keycloak-web.sh` y exigir su mensaje final. No basta con
reiniciar la imagen: Keycloak no sobrescribe un realm ya persistido.
