# CHANGE REQUEST — cerrar los gaps de infraestructura

> **Documento temporal.** Se creo el 2026-08-24 para dar contexto a una sesion
> de trabajo dedicada. **Borralo cuando las cinco tareas esten hechas**
> (`rm CHANGE-REQUEST.md`) — el contenido definitivo vive en PROPUESTA.md §8b.

---

## Contexto: lo que ya se hizo (no hace falta re-explorar)

El 2026-08-24 se aplico `envs/aws/` contra la cuenta **940213460779**
(us-east-1) por primera vez. Resultado: **88 recursos, 4 de 5 servicios
operativos, smoke test en verde** a traves del ALB publico. Todo se destruyo
despues; hoy la cuenta esta vacia.

El detalle completo esta en **PROPUESTA.md seccion 8b** — leelo primero, evita
repetir diagnostico. Resumen de lo que quedo **resuelto** y no hay que tocar:

| Ya arreglado | Donde |
|---|---|
| `runtime_platform` / arquitectura de imagen | `modules/ecs-service` (variable `cpu_architecture`) |
| TLS hacia RDS | `PGSSLMODE=no-verify` en `db_env` |
| Keycloak en modo produccion | `KC_HTTP_ENABLED`, `KC_PROXY_HEADERS`, `KC_HOSTNAME_STRICT`, `KC_DB_*` |
| Credenciales de RabbitMQ | `random_password` + Secrets Manager en `envs/aws/main.tf` |
| Secretos que bloqueaban el re-apply | `recovery_window_in_days = 0` |

**Hallazgo estructural que explica casi todo:** `envs/local/main.tf` tenia las
variables de entorno correctas y `envs/aws/services.tf` no. Cuando dudes de que
variable pasar, **compara los dos archivos** — `envs/local` es la referencia
que ya funciono.

### Reglas de trabajo

1. **No apliques contra AWS sin autorizacion explicita del usuario.** El stack
   completo cuesta ~$0.25/hora. `terraform validate` y `terraform plan`
   (este ultimo requiere credenciales pero no crea nada) son suficientes para
   todo lo que sigue.
2. **`envs/local` no debe cambiar de comportamiento.** Toda variable nueva en
   un modulo compartido va con un default que preserve lo actual. El patron ya
   usado es `default = null` + bloque `dynamic` (ver `cpu_architecture` en
   `modules/ecs-service/main.tf`).
3. Corre `terraform fmt -recursive .` y `terraform validate` en **ambos**
   entornos antes de dar algo por terminado.

---

## T1 · Modulo de migracion del esquema

**Prioridad: alta.** Es el unico gap que deja el entorno inservible.

### El problema

`docker-compose.yml` (repo ProjectUVG) monta `CONGENIA-M1-SERVER/db/init` en
`/docker-entrypoint-initdb.d`, y Postgres corre `01_schema.sql` y `02_seed.sql`
al crear el contenedor. **RDS no tiene ese mecanismo.** Terraform crea la
instancia y el esquema no lo pone nadie: la API arranca contra una base sin
tablas.

### Lo que se hizo a mano (funciono, replicalo en Terraform)

Una tarea ECS de un solo uso con `postgres:16-alpine`, en subred privada
(`app`), que descarga los `.sql` y los aplica con `psql`. Resultado: 23 tablas
y los seeds. Se eligio asi porque RDS es `publicly_accessible = false` y llegar
desde una maquina del equipo exigiria Client VPN (~$0.20/hora solo por el
endpoint) o un bastion.

Dos defectos de la version manual **que hay que corregir**:

- El password viajo como `environment` de la tarea, visible en
  `describe-task-definition`. Debe ir con el bloque `secrets` +
  `valueFrom` apuntando a `aws_secretsmanager_secret.db`.
- La tarea hacia `apk add curl` al arrancar, lo que la ata al NAT Gateway.

### Decision de diseno pendiente

Terraform **no tiene** un recurso nativo para "ejecutar una tarea una vez".
Dos caminos, elegi uno y documentalo:

- **(a) Recomendado** — Terraform declara solo la `aws_ecs_task_definition` de
  migracion; un target `make migrate` la ejecuta con `aws ecs run-task` y
  espera con `aws ecs wait tasks-stopped`. Mantiene Terraform declarativo y el
  paso imperativo explicito.
- **(b)** `null_resource` con `local-exec`. Se ejecuta dentro del `apply`, pero
  mete logica imperativa en el estado y exige el AWS CLI en quien aplique.

Y para meter los `.sql` en el contenedor, tambien dos caminos:

- **(a) Recomendado** — una imagen propia (`congenia/migrate` en ECR) con los
  `.sql` horneados. Sin dependencia de red, sin URLs firmadas.
- **(b)** Dejar los `.sql` en S3 y darle al task role permiso de lectura sobre
  ese prefijo (ver T3).

### Archivos

- Nuevo: `modules/migrate/` (`main.tf`, `variables.tf`, `outputs.tf`)
- `envs/aws/main.tf` — instanciar el modulo
- `Makefile` — target `migrate` si vas por el camino (a)
- El execution role necesita permiso de Secrets Manager: hoy solo tiene
  `AmazonECSTaskExecutionRolePolicy` (`modules/platform/main.tf:60`), que
  **no** incluye `secretsmanager:GetSecretValue`.

### Verificacion

`terraform validate`. La prueba real requiere aplicar; no lo hagas sin permiso.

---

## T2 · Variables de entorno que faltan: `S3_ENDPOINT` y `REDIS_URL`

**Prioridad: alta. Esfuerzo: minutos.** Son las brechas 6 y 8 de PROPUESTA.md.

### Estado actual

`envs/aws/services.tf:34` define:

```hcl
s3_env = {
  S3_BUCKET = module.data.docs_bucket
  S3_REGION = var.region
}
```

`envs/local/main.tf:143` define **seis** variables:
`S3_ENDPOINT`, `S3_PUBLIC_ENDPOINT`, `S3_BUCKET`, `S3_REGION`,
`S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`.

Sin `S3_ENDPOINT` la app cae a su default `http://seaweedfs:8333` (definido en
`dist/config/env.js` de las imagenes) y `pdf-worker` muere al arrancar con
`getaddrinfo ENOTFOUND seaweedfs`. **Es la razon por la que quedo 0/2.**

`REDIS_URL` no se pasa en ninguna parte de `envs/aws`. El cluster de
ElastiCache se crea, se factura (~$12/mes) y ningun contenedor lo usa.
`envs/local/main.tf:227` si lo pasa, y `docker-compose.yml:99` tambien.

### Cambio

En `envs/aws/services.tf`, dentro del bloque `locals`:

- Agregar `S3_ENDPOINT = "https://s3.${var.region}.amazonaws.com"`.
- Evaluar `S3_FORCE_PATH_STYLE` — el cliente lo lee (`dist/lib/s3.js`). Para
  S3 real deberia ser `false`; en SeaweedFS era `true`.
- Agregar un `redis_env` con `REDIS_URL`. Los outputs ya existen:
  `module.data.redis_address` y `module.data.redis_port`
  (`modules/data/outputs.tf:17` y `:21`).
- Sumar `redis_env` al `merge(...)` del modulo `api`
  (`envs/aws/services.tf:127`). Verificar si `pdf_worker` (linea 162) tambien
  lo necesita — revisa `dist/config/env.js` de la imagen del worker.

### Ojo con la autenticacion de Redis

El `redis` del compose arranca con `--requirepass` (`docker-compose.yml:63`) y
la URL lleva password (`redis://:PASS@redis:6379`). Pero `modules/data/main.tf:47`
crea el cluster **sin** `auth_token`. Decidi una de dos y documentala:

- Sin auth: `REDIS_URL = "redis://ADDR:PORT"`, confiando en el aislamiento por
  security group y NACL.
- Con auth: exige `transit_encryption_enabled = true` en ElastiCache y cambia
  el esquema a `rediss://`.

### Nota importante

`S3_ACCESS_KEY_ID` y `S3_SECRET_ACCESS_KEY` **no** los agregues con llaves
estaticas. Ese es el nudo de T3 y de un cambio de codigo que esta fuera de
alcance (ver la seccion final).

---

## T3 · El task role no tiene ninguna politica

**Prioridad: alta.**

### Estado actual

`modules/platform/main.tf:66` crea `aws_iam_role.task` con su politica de
confianza y **nada mas**. Verificado en la cuenta durante la prueba:
`list-attached-role-policies` y `list-role-policies` devolvieron vacio.

La aplicacion no puede leer ni escribir en el bucket de documentos ni leer
secretos en tiempo de ejecucion.

### Cambio

En `modules/platform/`:

- `aws_iam_policy_document` con permisos sobre el bucket:
  `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` sobre `${bucket_arn}/*`, y
  `s3:ListBucket` sobre el bucket. **Acotado a ese bucket**, no `*`.
- Adjuntarla a `aws_iam_role.task`.
- Nueva variable `docs_bucket_arn` (hoy el modulo `platform` no conoce el
  bucket; `modules/data/outputs.tf` expone `docs_bucket` pero es el **id**, no
  el ARN — probablemente convenga agregar un output `docs_bucket_arn`).
- Cuidado con el ciclo entre modulos: `platform` pasaria a depender de `data`.
  Si molesta, pasa el ARN desde `envs/aws/main.tf` como variable.

### Advertencia que hay que tener presente

**Arreglar el rol no es suficiente para que funcione S3.** `src/lib/s3.ts` (en
CONGENIA-M1-PDF-WORKER y equivalente en el server) construye el cliente asi:

```ts
const s3Client = new S3Client({
  endpoint: env.S3_ENDPOINT,
  region: env.S3_REGION,
  forcePathStyle: env.S3_FORCE_PATH_STYLE,
  credentials: {                       // <-- siempre explicitas
    accessKeyId: env.S3_ACCESS_KEY_ID,
    secretAccessKey: env.S3_SECRET_ACCESS_KEY,
  },
});
```

Como `credentials` se pasa siempre, el SDK **nunca** consulta la cadena de
credenciales del contenedor y el rol IAM queda inutil. El cambio de codigo esta
fuera del alcance de este documento, pero la politica del rol es prerequisito
y hay que dejarla lista.

---

## T4 · El entorno no se puede destruir de un tiron

**Prioridad: media. Esfuerzo: bajo.** Es la brecha 9.

### Estado actual

`terraform destroy` fallo en dos puntos durante la prueba:

- `modules/data/main.tf:63` — `aws_s3_bucket.docs` sin `force_destroy`. Y como
  tiene versionado (`:78`), borrar los objetos no basta: quedan versiones y
  marcadores de borrado.
- `modules/platform/main.tf:17` — `aws_ecr_repository` sin `force_delete`.
  Ademas, vaciarlo de una pasada no alcanza: una imagen subida como indice OCI
  deja manifiestos hijos huerfanos **sin etiqueta** al borrar el indice, y esos
  siguen bloqueando. Hay que iterar hasta que `list-images` devuelva vacio.

### Cambio

Exponer ambas como variables en lugar de dejarlas fijas, de modo que
produccion siga protegida y un entorno efimero se baje limpio:

```hcl
variable "ephemeral" {
  description = "Permite destruir bucket y repos ECR con contenido. Solo para entornos de prueba."
  type        = bool
  default     = false
}
```

Aplicarla a `force_destroy` del bucket y `force_delete` de los repos ECR.
Decidi si `envs/aws` la enciende (hoy es un entorno de prueba) o si se deja
apagada y se documenta el vaciado manual.

---

## T5 · Certificado ACM y listener 443

**Prioridad: media. BLOQUEADA — requiere exploracion primero.**

### Estado actual

`modules/edge/main.tf:44` solo declara `aws_lb_listener.http` en el puerto 80.
`modules/edge/variables.tf` no tiene ninguna variable para el ARN de un
certificado. O sea que **el recurso no existe**, no es que este apagado.

Por eso `envs/aws/services.tf` usa `http://` en `FRONTEND_BASE_URL`,
`CORS_ORIGINS` y `KC_HOSTNAME`.

### Lo que hay que averiguar antes de escribir codigo

**Un certificado publico de ACM exige un dominio que el equipo controle.**
Preguntale al usuario si CONGENIA tiene uno (y si esta en Route 53 o en otro
registrador). Sin dominio esta tarea no se puede completar — no la empieces a
ciegas.

### Cambio, si hay dominio

- `aws_acm_certificate` con validacion DNS + `aws_acm_certificate_validation`.
- Variable `certificate_arn` en `modules/edge` (default `null`).
- `aws_lb_listener` en 443 con `ssl_policy` y el certificado, emitido con un
  `dynamic` o un `count` para que `envs/local` no lo cree.
- Redirigir el listener 80 a 443 (`type = "redirect"`).
- Cambiar `http://` por `https://` en las tres variables de `services.tf`.
- Regla del security group edge: el 443 ya esta abierto, verificalo en
  `modules/network/security-groups.tf`.

---

## Fuera de alcance: cambios en los repos de aplicacion

No los hagas en este repositorio. Anotados aca solo para que no te sorprendan
al probar; el detalle esta en PROPUESTA.md §9.

| Cambio | Repo | Por que |
|---|---|---|
| Omitir `credentials` en `S3Client` cuando no hay llaves | CONGENIA-M1-SERVER, CONGENIA-M1-PDF-WORKER | Sin esto el rol IAM de T3 no sirve |
| Declarar `ssl` en el Pool de `src/config/db.js` | CONGENIA-M1-SERVER | Hoy depende de `PGSSLMODE` en el entorno |
| `VITE_API_BASE_URL` en tiempo de arranque | CONGENIA-M1 | Hoy se hornea en build; la imagen actual apunta a `http://159.89.88.142:3000` |
| Importar el realm `congenia` en Keycloak | — | En AWS solo existe `master`; `/realms/congenia` da 404 |

---

## Al terminar

1. `terraform fmt -recursive .`
2. `terraform validate` en `envs/aws` **y** en `envs/local`
3. Confirmar que `envs/local` no cambio de comportamiento (`terraform plan`
   contra MiniStack no deberia mostrar cambios inesperados)
4. Actualizar **PROPUESTA.md §8b** marcando como resueltas las brechas
   cerradas, y **§9** quitando las tareas hechas
5. Commit
6. **`rm CHANGE-REQUEST.md`** y commitear el borrado
