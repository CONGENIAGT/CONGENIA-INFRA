# PROPUESTA — Infraestructura como codigo para CONGENIA

**Fecha:** 22 de agosto de 2026
**Alcance:** hasta Terraform, como se pidio.
**Estado:** el stack completo esta aplicado y corriendo contra MiniStack.
85 recursos en estado, 7 contenedores reales, smoke test en verde.

---

## 1. Resumen

Se construyo **CONGENIA-INFRA**, un repositorio de Terraform que describe toda
la plataforma y se aplica igual en local que en AWS. No es un boceto: se
ejecuto contra el MiniStack que ya estaba levantado y el recorrido
`navegador → ALB → tarea privada → PostgreSQL` funciona de punta a punta.

Lo que quedo corriendo:

| Componente | Recurso Terraform | Evidencia |
|---|---|---|
| PostgreSQL | `aws_db_instance` | contenedor `postgres:16-alpine`, la API loguea `[DB] Connected to PostgreSQL` |
| Redis | `aws_elasticache_cluster` | contenedor `redis:7-alpine` |
| Bucket de imagenes y PDFs | `aws_s3_bucket` | S3 nativo de MiniStack |
| Keycloak | `aws_ecs_service` | responde `/realms/master` con su clave publica |
| RabbitMQ | `aws_ecs_service` | el worker loguea `Worker is now consuming messages` |
| API MedicalRecord | `aws_ecs_service` | responde JSON en `/v1/*` y `/api/*` |
| PDF Worker | `aws_ecs_service` | consumiendo la cola `consent.pdf.generate` |
| Frontend (ficha) | `aws_ecs_service` | sirve `Ficha Genetica - Congenia` |
| Punto de entrada | `aws_lb` + reglas | enruta por path a los tres destinos |

El diagrama esta en [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md).

---

## 2. La decision de fondo: por que no "todo dentro de una EC2"

El `.tf` de partida consolidaba la aplicacion en dos instancias EC2 (un proxy
Nginx en la DMZ y una instancia grande con `docker-compose` dentro) para
esquivar el costo de Fargate, RDS Multi-AZ, ElastiCache y Amazon MQ.
**Ese plan no es verificable en local, y lo comprobamos aplicandolo.**

Se ejecuto el archivo tal cual. Resultado:

1. `terraform validate` falla: el bloque `provider` declara un endpoint `vpc`,
   que no existe en el provider de AWS. Las operaciones de VPC viajan por el
   endpoint `ec2`. Quitando esa linea, aplica.
2. Aplica los 10 recursos sin error, con `ami-mock-ubuntu` como AMI: MiniStack
   no valida el identificador.
3. **`docker ps` no muestra nada.** Las instancias existen como registros de
   metadatos en estado `running`, con IP privada y publica asignadas, pero
   detras no hay maquina. El `user_data` que instala Docker y levanta el
   `docker-compose` **nunca se ejecuta**.

Es el comportamiento documentado de MiniStack: `RunInstances` devuelve
metadatos, que es lo correcto para stacks llenos de AMIs que no existen. Hay
una via para obtener una caja real (`RegisterImage` apuntando a una imagen de
contenedor), pero un contenedor no es una VM: no hay IMDS, ni consola, ni
`user_data`, ni aplicacion de security groups.

La consecuencia es concreta: la Fase 3 del encargo original — *inyectar el
docker-compose en la EC2, configurar el Nginx y correr healthchecks por el
puerto 80* — **no se puede automatizar ni probar por esa via**. Se estaria
entregando un `terraform apply` verde sobre una infraestructura vacia.

Por el contrario, ECS en MiniStack **arranca contenedores Docker reales**, RDS
levanta un Postgres real y ElastiCache un Redis real. Esa es la unica ruta por
la que el entorno local se parece a lo que se va a desplegar.

> **El costo no se pierde de vista.** La palanca de costo en AWS real no es
> "EC2 en vez de ECS", es el *tipo de capacidad* de ECS. El modulo
> `ecs-service` expone `launch_type`: con `EC2` las mismas definiciones de
> servicio corren sobre una sola instancia del cluster, sin tocar una linea de
> los servicios. Ver la seccion 8.

---

## 3. El repositorio nuevo: CONGENIA-INFRA

ProjectUVG (CONGENIA-ORCH) funciona hoy como orquestador: integra varios
repositorios y su artefacto es un `docker-compose.yml`. Con Terraform la
naturaleza del trabajo cambia — se pasa de *arrancar contenedores en una
maquina* a *describir recursos con estado* — y por eso conviene un repositorio
aparte en vez de meterlo dentro del orquestador.

**Razon principal:** Terraform tiene **estado**. Un `terraform.tfstate` es la
fuente de verdad de lo que existe; si se mezcla con el repo que se clona para
desarrollo, tarde o temprano alguien lo pisa o lo commitea. El estado necesita
su propio ciclo de vida, su bloqueo y su backend remoto.

```
CONGENIA-INFRA/
├── modules/
│   ├── network/      VPC de 3 capas + cadena de security groups
│   ├── data/         RDS, ElastiCache, S3
│   ├── platform/     cluster ECS, ECR, log groups, roles IAM
│   ├── ecs-service/  modulo reutilizable: 1 servicio del compose = 1 llamada
│   └── edge/         ALB, target groups, reglas por path
├── envs/
│   ├── local/        MiniStack — aplicado y probado
│   └── aws/          AWS real — valida, sin aplicar
└── scripts/          reconciliacion local y smoke tests
```

Los dos entornos **llaman a los mismos modulos**. La unica diferencia
estructural es el bloque `endpoints` del provider. Eso es lo que hace que
probar en local signifique algo.

### Como encaja con los repos existentes

| Repositorio | Sigue igual | Cambia |
|---|---|---|
| `CONGENIA-M1` (frontend) | codigo y Dockerfile | publica su imagen a ECR |
| `CONGENIA-M1-SERVER` (API) | codigo y Dockerfile | publica su imagen a ECR |
| `CONGENIA-M1-PDF-WORKER` | codigo y Dockerfile | publica su imagen a ECR |
| `CONGENIA-DB` | esquema y documentacion | sin cambios |
| `CONGENIA-ORCH` (ProjectUVG) | `docker-compose.yml` para desarrollo del dia a dia | deja de ser el mecanismo de despliegue |
| **`CONGENIA-INFRA`** *(nuevo)* | — | despliegue e infraestructura |

El `docker-compose.yml` **no se tira**. Sigue siendo la forma mas rapida de
levantar el stack para picar codigo. Lo que deja de ser es *la forma de
desplegar*. Son dos cosas distintas que hoy estan en el mismo archivo.

### El dia a dia

```
Desarrollador de un servicio
  └─ cambia codigo → push → CI construye y publica la imagen a ECR
                                        │
Encargado de infraestructura            ▼
  └─ actualiza image_tag en CONGENIA-INFRA → PR → plan revisado → apply
```

`terraform plan` en un PR muestra exactamente que va a cambiar antes de que
cambie. Esa revision es lo que hoy no existe.

---

## 4. Servicios que hubo que agregar

El `docker-compose.yml` tiene 8 servicios. La plataforma necesita 6 piezas mas
que en Docker estaban implicitas o simplemente no existian:

| Pieza | Por que | En el compose |
|---|---|---|
| **ALB** | Unico punto de entrada y reglas por path | El diseno original ponia un Nginx en una EC2. Un ALB hace lo mismo sin servidor que parchear. |
| **ECR** | Registro de imagenes con control de acceso | Hoy se usa una cuenta personal de Docker Hub (ver seccion 6.7). |
| **NAT Gateway** | Salida a internet de subredes privadas | En Docker todo salia por el bridge. |
| **CloudWatch Logs** | Un log group por servicio | Era `docker logs`, que se pierde al recrear el contenedor. |
| **Roles IAM** | Ejecucion de tareas y permisos de la aplicacion | No aplicaba. |
| **Cloud Map** | Descubrimiento por DNS privado entre servicios | Docker resolvia por nombre de servicio. |

Y una sustitucion que sale gratis: **SeaweedFS desaparece**. La aplicacion ya
hablaba protocolo S3 a traves de `S3_ENDPOINT`, asi que basta apuntar esa
variable a un bucket. Es un componente menos que operar, sin cambios de codigo.

---

## 5. Lo que Terraform no automatiza, y con que se cubre

Esta es la respuesta directa al punto 3 del encargo.

**En AWS real, Terraform cubre todo lo que se describe aqui.** No hace falta
otra herramienta para la infraestructura.

**Contra MiniStack hay dos integraciones que el emulador no ejecuta**, y ambas
requieren un paso de reconciliacion posterior al apply. Esta implementado en
[`scripts/reconcile_alb.py`](scripts/reconcile_alb.py) y se corre con
`make reconcile`:

### 5.1 El registro de tareas ECS en el ALB

En AWS real, el bloque `load_balancer` de `aws_ecs_service` registra y da de
baja las IPs de las tareas automaticamente. MiniStack acepta el bloque pero no
lo ejecuta: el target group queda vacio.

No es algo que Terraform pueda resolver por si solo, porque la IP de la tarea
no se conoce en tiempo de `plan`. El script consulta las tareas del servicio,
resuelve la IP del contenedor que las respalda y llama a `RegisterTargets`.

### 5.2 Las condiciones de las reglas del listener

Este fue el mas dificil de detectar, porque **se disfraza de exito**.

El provider de AWS v6 manda las condiciones de path como
`Conditions.member.N.PathPatternConfig.Values.member.M`. MiniStack solo lee la
forma antigua, `Conditions.member.N.Values.member.M`
(`ministack/services/alb.py`, funcion `_parse_conditions`). El resultado es que
la regla se crea con la lista de patrones **vacia**, no hace match nunca, y
todo el trafico cae al destino por defecto.

Sintoma: `DescribeRules` devuelve las reglas con la prioridad y el target group
correctos, pero `<Values></Values>`. Y como el destino por defecto es el
frontend, **todas las rutas devuelven HTTP 200**. Un smoke test que solo mire
codigos de respuesta da verde con el enrutamiento completamente roto. Nos paso:
`/health` devolvia la respuesta del propio gateway de MiniStack y
`/realms/congenia` devolvia el HTML del frontend.

Dos consecuencias que quedan en el repositorio:

- El script reescribe cada regla en el formato que MiniStack si entiende.
- **`scripts/smoke-test.sh` verifica contenido, no codigos HTTP.** Comprueba que
  `/` traiga el titulo de la ficha, que `/v1/*` traiga JSON de la API y que
  `/realms/master` traiga la clave publica de Keycloak.

Ninguno de los dos parches se usa en AWS real. Estan aislados en `scripts/` y
el codigo de Terraform no los conoce.

---

## 5b. Endurecimiento de la arquitectura

La migracion no es solo mover contenedores: la red gana controles que en
Docker no existian. Estos son los que quedaron, y en que estado.

### Lo que ya estaba y sigue

| Control | Donde |
|---|---|
| **NAT Gateway** | `modules/network` — salida controlada de las subredes privadas, con EIP fija |
| **Logs de aplicacion** | `modules/platform` — un log group de CloudWatch por servicio |
| **Cadena de security groups** | `modules/network` — edge acepta internet, app solo acepta al ALB, data solo acepta a app |

### Lo que se agrego

| Control | Recurso | Local | AWS |
|---|---|---|---|
| **WAF de capa 7** | `aws_wafv2_web_acl` + asociacion al ALB | aplicado | si |
| **Flow Logs de VPC** | `aws_flow_log` a CloudWatch | aplicado | si |
| **NACLs por capa** | `aws_network_acl` + 10 reglas | reglas aplicadas | si |
| **Asociacion de NACLs** | `aws_network_acl_association` | **no** (6.9) | si |
| **Endpoint S3** | `aws_vpc_endpoint` tipo gateway | aplicado | si |
| **Endpoints de interface** | ECR (api y dkr), Logs, Secrets Manager | aplicado | si |
| **VPN sitio a sitio** | `aws_vpn_connection` + propagacion de rutas | **no** (6.10) | si |
| **VPN de operadores** | `aws_ec2_client_vpn_endpoint` | **no** (6.11) | si |

**El WAF y los security groups no se solapan.** Un security group decide
*quien puede abrir una conexion*; el WAF decide *que peticiones pasan* una vez
abierta. El WebACL trae tres grupos administrados de AWS (OWASP comunes,
entradas maliciosas conocidas, inyeccion SQL) y un limite de 2000 peticiones
por IP cada cinco minutos, que es el freno de fuerza bruta contra Keycloak.

**Los flow logs son distintos de los log groups que ya existian.** Aquellos
recogen el stdout de cada contenedor; estos registran la capa de red — quien
hablo con quien, aceptado y rechazado. Son los que permiten auditar si un
security group esta dejando pasar algo que no deberia.

**Las NACL son sin estado, y por eso valen la pena.** Un security group solo
sabe permitir; una NACL puede denegar explicitamente. Como no tiene estado,
hay que abrir el rango efimero de vuelta a mano — por eso cada capa tiene una
regla `ephemeral` que a primera vista parece de mas.

**Los VPC endpoints reducen dos cosas a la vez:** la superficie expuesta (las
tareas privadas alcanzan ECR, CloudWatch y Secrets Manager sin ruta a
internet) y la factura, porque ese trafico deja de pasar por el NAT Gateway,
que se cobra por GB.

### Acceso a los recursos privados

Hoy la unica puerta es el ALB, y solo publica tres rutas. RDS, Redis, RabbitMQ
y la consola de gestion **no son alcanzables desde fuera**, que es lo correcto,
pero el equipo necesita llegar a ellos para operar.

La propuesta es **Client VPN con autenticacion mutua por certificado**, no un
bastion: no abre ningun puerto de entrada, no hay una maquina que parchear, y
las conexiones quedan registradas en su propio log group. Esta escrito en
`modules/vpn` y se enciende con `enable_client_vpn`. No se pudo probar porque
MiniStack no implementa Client VPN (6.11); necesita dos certificados en ACM
antes del primer apply.

Para el tunel hacia la base de datos externa de Nursera hace falta que el otro
dominio entregue tres datos: IP publica de su gateway, ASN y los rangos
alcanzables. Sin eso el recurso no se puede escribir con valores reales.

---

## 6. Limites encontrados en MiniStack

Todos verificados ejecutandolos, no leyendo documentacion.

| # | Hallazgo | Impacto |
|---|---|---|
| 6.1 | El endpoint `vpc` del `.tf` original no existe en el provider | `validate` falla; se quita esa linea |
| 6.2 | `aws_instance` es solo metadatos: `user_data` no corre | Invalida el enfoque "docker-compose dentro de una EC2" |
| 6.3 | `aws_ecs_service.load_balancer` no puebla el target group | Reconciliacion posterior (5.1) |
| 6.4 | `CreateRule` ignora `PathPatternConfig` | Enrutamiento roto que aparenta funcionar (5.2) |
| 6.5 | `ModifyListener` no refresca el plano de datos | Cambiar la accion por defecto exige recrear el listener |
| 6.6 | Amazon MQ no levanta broker real | RabbitMQ corre como tarea ECS |
| 6.7 | Un fallo al halar la imagen deja la tarea en `RUNNING` | Tarea fantasma sin contenedor; hay que mirar `docker ps` |
| 6.8 | ElastiCache reporta el puerto del host, no el del cluster | Recreaba el cluster en cada apply; se deja `port` sin declarar |
| 6.9 | `DescribeNetworkAcls` ignora el filtro `association.subnet-id` | Devuelve las 4 NACL de la cuenta y el provider aborta con "too many results: wanted 1, got 4". Las NACL y sus reglas si se crean; solo la asociacion queda fuera |
| 6.10 | `aws_vpn_connection` falla al leerse | El recurso se crea, pero el provider consulta despues `DescribeTransitGatewayAttachments`, accion que MiniStack no implementa, y aborta el apply |
| 6.11 | Client VPN no existe | `DescribeClientVpnEndpoints` responde "Unknown EC2 action" |
| 6.12 | AWS Network Firewall no existe como servicio | El filtrado de perimetro se cubre con WAFv2, que si esta disponible |

### 6.7 en detalle: la distribucion de imagenes

Al aplicar, el `pdf-worker` no arrancaba. MiniStack registraba:

```
pull access denied for xavierlopez25/congenia, repository does not exist
or may require 'docker login'
```

**`xavierlopez25/congenia` es un repositorio privado de Docker Hub.** Un pull
anonimo responde 401 para todos los tags. La API y el frontend si arrancaron,
pero solo porque sus imagenes ya estaban en la cache local de esta maquina.

Es un riesgo de continuidad serio: el despliegue depende hoy de la cuenta
personal de un integrante. Ademas las imagenes son **solo `linux/amd64`**, lo
que obliga a emulacion en las Mac ARM del equipo.

Por eso el modulo `platform` crea tres repositorios ECR, y por eso el entorno
local construye desde el codigo fuente (`make images`) en vez de depender de
Docker Hub. Con eso los tres servicios arrancan sin credenciales de nadie.

### Ruido de fidelidad, sin impacto

Tras estabilizar el stack, `terraform plan` deja 6 cambios *in-place*
permanentes sobre atributos que MiniStack no devuelve igual que AWS
(`max_allocated_storage`, `auto_minor_version_upgrade`, `security_group_ids` de
ElastiCache, `subnet_ids` del subnet group, y `tags` en reglas y EIP). Son
idempotentes y no recrean nada. **En AWS real no aparecen.**

---

## 7. Lo que no existe todavia

El diagrama de arquitectura que se dio como entrada incluye componentes que
**no estan en el repositorio**. Conviene decirlo explicitamente porque cambia
la planificacion:

| Componente del diagrama | Estado |
|---|---|
| API AnalyticsService | No existe codigo ni Dockerfile |
| Webapp Dashboard de analisis | No existe |
| Agent de consultas (LLM) | No existe |
| Acceso a NurseraAPI | No hay cliente en la API |
| DB externa en red privada ajena | Requiere VPN Site-to-Site y datos que no tenemos |

La infraestructura para los tres primeros es **una llamada mas al modulo
`ecs-service` cada uno** — el modulo ya es generico. Lo que falta es el codigo.

Las dos ultimas si necesitan decisiones que no podemos tomar solos: la VPN
exige el bloque CIDR, la IP publica del gateway remoto y una clave compartida
del otro dominio. Mientras no existan, no tiene sentido escribirlas.

---

## 8. Camino a AWS real

`envs/aws/` existe, valida, y **no se ha aplicado**: aplicarlo genera costo.
Reutiliza los mismos modulos y cambia solo lo que debe cambiar:

- Sin bloque `endpoints`.
- Contrasenas desde Secrets Manager, nunca en `tfvars`.
- Imagenes desde ECR en vez de Docker Hub.
- Descubrimiento por Cloud Map en vez de `host.docker.internal`.
- Estado remoto en S3 con bloqueo.
- Sin scripts de reconciliacion: las integraciones son nativas.

### Sobre el costo

La preocupacion original era el gasto de los servicios administrados. Tres
palancas, en orden de impacto:

1. **`launch_type = "EC2"`** en el modulo `ecs-service`. Las tareas corren
   sobre instancias del cluster en vez de Fargate. Se paga una VM, no cada
   tarea, y **no cambia ninguna definicion de servicio**.
2. **`multi_az = false`** en RDS, que ya es el valor por defecto.
3. **`enable_nat_gateway = false`** si ningun servicio necesita salida a
   internet todavia. El NAT Gateway tiene costo por hora y por GB, y hoy solo
   lo justifica la llamada a NurseraAPI, que aun no existe.

La diferencia frente al plan original es que estas son **variables**, no una
arquitectura distinta. Se puede empezar barato y subir sin reescribir nada.

### Antes del primer apply en AWS

1. Crear a mano el bucket de estado y habilitar bloqueo.
2. Construir y publicar las tres imagenes a ECR como `linux/amd64` **y**
   `linux/arm64`.
3. Cargar los secretos con `aws secretsmanager put-secret-value`.
4. Certificado en ACM y listener 443 (hoy el ALB solo tiene 80).
5. Emitir los dos certificados de Client VPN (servidor y raiz de cliente) si se
   quiere acceso del equipo a la red privada.
6. Poner `associate_nacls = true` — en AWS el filtro funciona.
7. Revisar el `plan` entre dos personas.

---

## 8b. Resultado del primer apply en AWS real

Esta seccion ya no es plan: es el registro de lo que paso al aplicar el stack
contra la cuenta `940213460779` (us-east-1) el 2026-08-24.

**Resultado: 88 recursos creados, 4 de 5 servicios operativos, smoke test en
verde a traves del ALB publico.**

```
frontend   /                 200   nginx sirviendo el SPA
api        /health           200   {"status":"ok"}   <- conectado a RDS
api        /v1/ping          404   esperado, igual que en local
keycloak   /realms/master    200
keycloak   /admin/           302   redirige al login
```

### Lo que se confirmo

Dos suposiciones del documento quedaron probadas:

- **El registro de tareas en el ALB es nativo.** Los targets aparecieron
  `healthy` solos. `scripts/reconcile-alb.sh` no hizo falta: los dos parches
  que MiniStack exigia (seccion 5) son efectivamente artefactos del emulador.
- **Las NACL se asocian sin problema.** `associate_nacls = true` funciono.

### Siete brechas que solo aparecen al aplicar de verdad

`envs/aws/` validaba con `terraform validate` desde el principio. Validar no
detecta nada de lo siguiente, porque son incompatibilidades entre la
configuracion y el comportamiento real de los servicios:

| # | Brecha | Sintoma | Estado |
|---|---|---|---|
| 1 | `runtime_platform` no se declaraba | Fargate asume X86_64; una imagen arm64 no arranca | **Resuelto**: variable `cpu_architecture` en `modules/ecs-service` |
| 2 | RDS exige TLS (`rds.force_ssl=1`) | `no pg_hba.conf entry ... no encryption` | **Mitigado**: `PGSSLMODE=no-verify`. El codigo deberia declarar `ssl` |
| 3 | Keycloak arranca con `start` (produccion) | Exige HTTPS; exit 2 | **Resuelto**: `KC_HTTP_ENABLED`, `KC_PROXY_HEADERS`, `KC_HOSTNAME_STRICT`, y las credenciales `KC_DB_*` que faltaban |
| 4 | RabbitMQ sin credenciales | `RABBITMQ_USER/PASSWORD` undefined; `guest` solo acepta localhost | **Resuelto**: usuario propio generado con `random_password` |
| 5 | El esquema de la base no se carga solo | RDS nace vacio; no existe `docker-entrypoint-initdb.d` | **Resuelto a mano**; falta dejarlo en Terraform |
| 6 | `S3_ENDPOINT` no se pasaba | La app cae a su default `http://seaweedfs:8333` | **Pendiente** |
| 7 | La aplicacion no puede usar roles IAM para S3 | `S3Client` recibe `credentials` explicitas siempre | **Pendiente**: requiere cambio de codigo |
| 8 | `REDIS_URL` no se pasaba | ElastiCache creado y facturado, pero ningun servicio lo usa | **Pendiente** |
| 9 | El entorno no se puede destruir de un tiron | `BucketNotEmpty` y `RepositoryNotEmpty` | **Pendiente** |

### 8b.-1 El entorno no se destruye solo

Vale anotarlo porque afecta a cualquiera que quiera levantar el stack para una
demo y bajarlo despues. `terraform destroy` falla en dos puntos:

- **`aws_s3_bucket.docs`** no declara `force_destroy`. Y como el bucket tiene
  versionado, borrar los objetos tampoco basta: quedan las versiones y los
  marcadores de borrado, que siguen contando como contenido.
- **`aws_ecr_repository`** no declara `force_delete`, asi que un repositorio
  con imagenes publicadas bloquea la destruccion. Y vaciarlo de una pasada no
  alcanza: una imagen subida como indice OCI —lo que produce `docker buildx
  imagetools create`— tiene manifiestos hijos (la plataforma y el registro de
  procedencia) que quedan huerfanos y **sin etiqueta** al borrar el indice, y
  siguen bloqueando el borrado. Hay que iterar hasta que `list-images`
  devuelva vacio.

En un entorno productivo esas protecciones son deseables: evitan borrar datos
por accidente. Para entornos efimeros conviene exponerlas como variables
(`force_destroy = var.ephemeral`) en vez de dejarlas fijas, de modo que
produccion siga protegida y un entorno de prueba se pueda bajar limpio.

Mientras tanto hay que vaciar ambos a mano antes del `destroy`.

### 8b.0 Redis: creado, facturado, sin conectar

Merece parrafo aparte porque no da error: simplemente no se usa.

`docker-compose.yml` pasa `REDIS_URL` a la API (linea 99) y `envs/local`
tambien (linea 227). **`envs/aws` no.** El cluster de ElastiCache se crea, se
factura (~$12/mes) y ningun contenedor lo alcanza.

Importa mas de lo que parece: segun el diseno del modulo, Redis guarda el
payload de `POST /sessions/init` bajo la clave que luego viaja cifrada en el
header `X-Session-Token`. Sin Redis, ese flujo completo —que es la puerta de
entrada de la integracion— no funciona en AWS.

No lo detecto el smoke test porque `/health` responde `{"status":"ok"}` sin
comprobar Redis. Es un recordatorio de que un health check que solo confirma
que el proceso esta vivo no dice nada sobre sus dependencias.

Hay un segundo detalle al conectarlo: el `redis` del compose arranca con
`--requirepass`, mientras que `modules/data` crea el cluster **sin**
`auth_token`. Habra que decidir si se activa autenticacion en ElastiCache
—lo cual exige TLS en transito— o si se confia solo en el aislamiento por
security group y NACL.

El patron es uno solo: **`envs/local` tenia las variables correctas y
`envs/aws` no.** El archivo de AWS se escribio por simetria con el de local
pero nunca se ejecuto, asi que las diferencias reales entre un Postgres en
contenedor y RDS —o entre SeaweedFS y S3— nunca se materializaron.

### 8b.1 El esquema de la base de datos

Es la brecha con mas consecuencias porque no tiene equivalente en AWS.

En local, `docker-compose.yml` monta `CONGENIA-M1-SERVER/db/init` en
`/docker-entrypoint-initdb.d`, y Postgres corre `01_schema.sql` y
`02_seed.sql` al crear el contenedor. **RDS no tiene ese mecanismo.**
Terraform crea la instancia; el esquema no lo pone nadie.

Se resolvio con una **tarea ECS de un solo uso** (`postgres:16-alpine`) que
corre dentro de la VPC, alcanza RDS por la red privada y aplica los dos
archivos. Resultado: 23 tablas y los seeds cargados.

Se eligio asi porque RDS vive en subred privada
(`publicly_accessible = false`) y llegar desde una maquina del equipo exigiria
**Client VPN** —certificados en ACM y ~$0.20/hora solo por tener el endpoint
asociado a dos subredes— o un bastion que hay que parchear. Una tarea ECS ya
esta dentro de la red, cuesta centavos y no deja nada atras.

Queda pendiente convertirla en un modulo de Terraform. Dos detalles a corregir
en esa version:

- El password viajo como variable de entorno de la tarea, visible en
  `describe-task-definition`. Debe usar el bloque `secrets` con `valueFrom`,
  lo que exige darle permiso de Secrets Manager al execution role.
- La tarea instala `curl` con `apk` al arrancar, y por lo tanto depende del
  NAT Gateway. Conviene hornear los `.sql` en una imagen propia en ECR.

### 8b.2 El rol de las tareas no tiene permisos

`modules/platform/main.tf` crea `aws_iam_role.task` con su politica de
confianza pero **no le adjunta ninguna politica de permisos**. Verificado en
la cuenta: `list-attached-role-policies` y `list-role-policies` devuelven
vacio.

La consecuencia es que la aplicacion no puede leer ni escribir en el bucket de
documentos ni leer secretos en tiempo de ejecucion — justo lo que necesita la
funcionalidad de pre-signed URLs.

Ahora bien, arreglar el rol **no basta**: `src/lib/s3.ts` construye el cliente
pasando siempre `credentials` explicitas, de modo que el SDK nunca consulta la
cadena de credenciales del contenedor. Mientras el codigo no omita ese bloque
cuando no hay llaves, el rol IAM es inutil y la unica alternativa son llaves
estaticas, que es exactamente lo que se queria evitar.

### 8b.3 Costo observado

El stack completo corriendo 24/7 sale del orden de **$170-230/mes**. Los
componentes que mas pesan, en orden: NAT Gateway (~$32-45), ALB (~$16-20),
los 4 endpoints de interface (~$29 en conjunto), RDS y ElastiCache (~$12-15
cada uno) y las tareas Fargate.

Dos matices sobre las palancas de la seccion anterior:

- **`enable_nat_gateway = false` no es gratis hoy.** Keycloak y RabbitMQ jalan
  sus imagenes de `quay.io` y Docker Hub, y sus tareas corren en subred
  privada. Sin NAT no hay forma de descargarlas. Para apagarlo hay que
  espejar tambien esas dos imagenes a ECR.
- **`launch_type = "EC2"` no esta conectado.** Los cinco servicios usan el
  default `FARGATE`, y no existe ningun modulo que cree las instancias ni el
  capacity provider que `EC2` necesitaria. La palanca esta descrita pero no
  implementada.

### 8b.4 Correcciones aplicadas al repositorio

- `modules/ecs-service`: variable `cpu_architecture` con bloque dinamico
  `runtime_platform`. Default `null`, asi que `envs/local` no cambia.
- `envs/aws/services.tf`: `PGSSLMODE`, credenciales de RabbitMQ, configuracion
  de proxy de Keycloak, `KC_DB_USERNAME`/`KC_DB_PASSWORD`, y `http://` en
  lugar de `https://` en `FRONTEND_BASE_URL` y `CORS_ORIGINS` mientras no
  exista el listener 443.
- `envs/aws/main.tf`: credenciales de RabbitMQ y del admin de Keycloak
  generadas con `random_password` y guardadas en Secrets Manager. A diferencia
  del password de Postgres, no requieren paso manual.
- `recovery_window_in_days = 0` en los tres secretos. Sin eso, `destroy` deja
  el nombre reservado 30 dias y el siguiente `apply` falla al recrearlo.

---

## 9. Siguientes pasos sugeridos

**Bloqueantes para que el stack quede completo** (los tres salieron del apply
real, seccion 8b):

1. **Dejar la carga del esquema en Terraform.** Hoy se hizo a mano con una
   tarea ECS. Sin esto, cada entorno nuevo nace con una base vacia y la API
   no sirve para nada. Es el mas urgente.
2. **Permitir que la aplicacion use roles IAM para S3.** Omitir el bloque
   `credentials` en `src/lib/s3.ts` cuando no hay llaves explicitas, y
   adjuntar al `task` role una politica sobre el bucket. Mientras no pase,
   `pdf-worker` no arranca en AWS y la unica alternativa son llaves estaticas.
3. **Pasar `S3_ENDPOINT` en `envs/aws`.** Sin la variable, la app busca el
   host `seaweedfs` que ya no existe.

**Antes de seguir construyendo:**

4. Mover las imagenes a ECR y sacar el despliegue de la cuenta personal de
   Docker Hub. **Hecho** durante la prueba: los tres repos ECR estan creados y
   poblados. Falta que el pipeline de cada repo publique ahi.
5. Construir multi-arquitectura (`amd64` + `arm64`). Hoy las imagenes de
   Docker Hub son solo `amd64`, lo que obliga a `cpu_architecture = "X86_64"`
   y cierra la puerta a Fargate Graviton, que es ~20% mas barato.
6. Importar el realm `keycloak/realm-congenia.json` desde Terraform. Hoy
   Keycloak arranca vacio y el realm `congenia` no existe. Confirmado en AWS:
   `/realms/master` responde, `/realms/congenia` no existiria.

**Para cerrar el endurecimiento:**

4. Pedir al dominio de Nursera los datos del tunel (IP del gateway, ASN,
   rangos) y encender `enable_site_to_site_vpn`.
5. Emitir los certificados de Client VPN y encender `enable_client_vpn`.

**Deuda conocida que conviene anotar:**

6. `VITE_API_BASE_URL` se quema en tiempo de build en la imagen del frontend.
   Cambiar el destino de la API obliga a reconstruir. Vale la pena moverlo a
   configuracion en tiempo de arranque.
7. El stack no tiene HTTPS todavia (listener 80).
8. RDS y ElastiCache no tienen backups configurados.

**Cuando exista el codigo:** AnalyticsService, Dashboard y Agent entran con una
llamada mas al modulo `ecs-service` cada uno.
