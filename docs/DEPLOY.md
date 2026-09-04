# CONGENIA: desplegar y apagar en AWS

Documento unico del ciclo de vida de la infraestructura: preparar la cuenta,
desplegar, y apagar.

La **parte 1** se hace una sola vez por cuenta AWS. Despues, desplegar es
`make up-aws` y todo lo demas esta en las partes 2 y 3.

El estado esta partido en dos stacks, y de ahi salen los dos niveles de
destruccion:

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

Se necesita Terraform >= 1.6 y AWS CLI v2. Docker solo hace falta para
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

### Solo para una cuenta que NO es la oficial

> **No ejecutar este bloque en la cuenta oficial de CONGENIA.** Sus valores por
> defecto ya son los correctos: bucket `congenia-tfstate`, prefijo `congenia`,
> dominio `cogenia.app`. Exportar estas variables ahi apunta el backend a un
> bucket inexistente —`init` falla con `NoSuchBucket`— y, peor, hace que el
> plan proponga una zona de Route 53 para un dominio de ejemplo que nadie
> controla.
>
> Si ya las exportaste por error:
>
> ```bash
> unset TF_CLI_ARGS_init TF_VAR_name_prefix TF_VAR_domain_name
> ```

Los nombres de bucket en S3 son globales, asi que una cuenta propia necesita el
suyo, un prefijo de recursos distinto y un dominio bajo su control. Estas tres
variables hay que reexportarlas **en cada terminal nueva**:

```bash
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export TF_CLI_ARGS_init="-reconfigure -backend-config=bucket=congenia-tfstate-${AWS_ACCOUNT_ID}"
export TF_VAR_name_prefix="congenia-$(printf '%s' "$AWS_ACCOUNT_ID" | cut -c 7-12)"
export TF_VAR_domain_name="tu-dominio-real.com"   # debe ser tuyo de verdad
```

El bucket de ese nombre hay que crearlo con los mismos cuatro comandos de
arriba, sustituyendo `BACKEND_BUCKET`.

## 1.4 Aplicar `envs/shared`

```bash
make init ENV=shared
terraform -chdir=envs/shared plan
```

**Leer el plan antes de aplicar.** En la cuenta oficial debe decir:

```text
+ resource "aws_route53_zone" "public" {
    + name = "cogenia.app"
+ resource "aws_iam_role" "ecr_push" {
    + name = "congenia-gha-ecr-push"
```

Si aparece otro dominio o el nombre lleva un sufijo numerico, hay variables de
1.3 exportadas que no corresponden. Corregir antes de continuar: aplicar asi
crea una zona alojada para un dominio ajeno y recursos con el prefijo
equivocado.

```bash
make create ENV=shared
```

Debe crear cinco repositorios ECR, el proveedor OIDC, un rol y una zona
alojada. Si termina bien, continuar en 1.5.

### Solo si el apply fallo con `EntityAlreadyExists`

> **No ejecutar este comando si el apply de arriba termino bien.** Una vez
> creado, el proveedor OIDC lo administra este estado; `create_oidc_provider =
> false` le dice a Terraform que no es suyo, y el siguiente apply **lo borra**.
> Eso deja a GitHub Actions sin identidad y los cinco workflows fallan con
> `AccessDenied`.
>
> Antes de usarlo, comprobar que Terraform no lo tenga ya:
>
> ```bash
> terraform -chdir=envs/shared state list | grep openid
> ```
>
> Si esa linea devuelve algo, el proveedor es tuyo y este bloque no aplica.

El proveedor OIDC de GitHub es **unico por cuenta AWS**: solo puede existir un
`token.actions.githubusercontent.com`. Si otro proyecto de la misma cuenta ya
lo creo, el apply falla asi:

```text
Error: creating IAM OIDC Provider: EntityAlreadyExists
```

Entonces, y solo entonces, se reutiliza el existente en lugar de duplicarlo:

```bash
make create ENV=shared TF_VARS='-var=create_oidc_provider=false'
```

Ese valor hay que pasarlo en **todos** los apply siguientes de `envs/shared`,
o Terraform volvera a intentar crearlo.

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

En la organizacion `CONGENIAGT`, no repo por repo.

**Variables de organizacion** — *Settings -> Secrets and variables -> Actions
-> Variables*, con alcance en los cinco repositorios:

| Variable | Valor |
|---|---|
| `AWS_ROLE_ARN` | salida `ci_role_arn` de 1.4 |
| `AWS_REGION` | `us-east-1` |
| `ECR_REGISTRY` | salida `ecr_registry` de 1.4 |

Van como variables y no escritas en los workflows para que cambiar de cuenta
AWS sea editar tres campos y no cinco archivos.

**Secreto `INFRA_TOKEN`** — es el permiso con el que el pipeline abre el PR que
registra la version publicada. *Settings -> Developer settings -> Personal
access tokens -> Fine-grained*:

- Repository access: **solo** `CONGENIAGT/CONGENIA-INFRA`.
- Permisos: `Contents: Read and write`, `Pull requests: Read and write`.
- Expiracion: 90 dias.

Registrarlo como secreto de organizacion con alcance en los cinco repos. Anotar
quien es el titular y cuando vence: al expirar, los builds siguen publicando en
ECR —eso usa OIDC— pero dejan de abrir PRs, y el sintoma no apunta al token de
forma obvia.

**Acceso al workflow reutilizable** — `bump-image-tag.yml` vive en
CONGENIA-INFRA y lo invocan los otros repos. En repositorios privados hay que
habilitarlo: *CONGENIA-INFRA -> Settings -> Actions -> General -> Access ->
Accessible from repositories in the organization*. Sin esto, el job `registrar`
falla con un error que no menciona los permisos.

## 1.7 Comprobar el OIDC y poblar ECR

Probar primero el repositorio mas simple: en `CONGENIA-M1-PDF-WORKER`, pestana
**Actions** -> `publish-image` -> **Run workflow**. Debe publicar
`congenia/pdf-worker:<version>-<sha>`.

```bash
aws ecr describe-images --repository-name congenia/pdf-worker \
  --query 'imageDetails[].imageTags' --output table
```

Si falla en `configure-aws-credentials` con `AccessDenied`, el sujeto OIDC no
coincide con la rama: revisar `var.ci_subjects` en `envs/shared`.

Repetir para los cinco: `publish-image` en `CONGENIA-M1`,
`CONGENIA-M1-SERVER` y `CONGENIA-M1-PDF-WORKER`, `publish-migrate` en
`CONGENIA-M1-SERVER`, y `publish-keycloak` en `CONGENIA-ORCH`. Cada uno abre un
PR aqui con su tag; mergearlos todos y comprobar que las cinco claves de
`envs/aws/images.tfvars` tengan un tag real.

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
`TF_VAR_name_prefix` y `TF_VAR_domain_name` de 1.3.

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
el rol `medico` y el usuario inicial.

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

./scripts/configure-keycloak-web.sh

unset KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_MEDICO_PASSWORD
```

Exigir el mensaje final:

```text
OK: congenia-web verificado con scopes profile, email y roles; usuario medico.inicial configurado.
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

## 2.6 Publicar una version nueva

Ya no se construye nada a mano.

1. Mergear en `main` (o `master`, en el orquestador) el cambio del servicio.
2. Su workflow corre las pruebas, publica la imagen en ECR y abre un PR aqui.
3. Revisar y mergear ese PR: eso registra que version deberia correr.
4. Aplicar:

```bash
git pull
export TF_VAR_enable_services=true
make plan ENV=aws
make open ENV=aws
```

`enable_services=true` es lo que distingue una actualizacion en caliente del
arranque en frio. Sin esa variable, `make plan` propondria apagar ECS.

Para publicar sin pasar por GitHub siguen existiendo `scripts/release-plan.sh`
en el orquestador y `make migrate-image ENV=aws`, que calculan exactamente los
mismos tags.

---

# Parte 3 — Apagar

## 3.1 Dormir los servicios

```bash
make close ENV=aws
```

Lleva Fargate a cero sin borrar datos ni red. NAT, ALB, RDS y Redis siguen
cobrando. Para una pausa de horas.

## 3.2 Destruir el entorno

```bash
make destroy ENV=aws CONFIRM_DESTROY=destroy-congenia-aws
make cost-status
```

Elimina todo el gasto significativo: NAT, ALB, RDS sin snapshot final, Redis,
Fargate, secretos y el bucket de documentos. **Conserva imagenes, DNS e
identidad de CI**, asi que volver es `make up-aws` sin republicar nada ni tocar
DNS.

Es el habito recomendado para una pausa larga. Los datos se pierden.

## 3.3 Nuke total

```bash
make nuke CONFIRM_DESTROY=destroy-congenia-todo
```

Destruye `envs/aws` y **despues** `envs/shared` —el orden es obligatorio,
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
delegacion en name.com, el `INFRA_TOKEN` y las variables de organizacion.

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

**El pipeline publica pero el PR no aparece.** Casi siempre es `INFRA_TOKEN`
expirado. El build sigue en verde porque publicar usa OIDC; lo que falla es el
job `registrar`. Ver 1.6.

**Keycloak devuelve `invalid_scope`.** Ejecutar
`scripts/configure-keycloak-web.sh` y exigir su mensaje final. No basta con
reiniciar la imagen: Keycloak no sobrescribe un realm ya persistido.
