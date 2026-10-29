"""Desplegar imagenes publicadas; limitar Terraform a los componentes elegidos."""
import argparse
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile

MODULES = {"api": "api", "frontend": "frontend", "pdf-worker": "pdf_worker", "keycloak": "keycloak", "migrate": "migrate"}
COMPONENTS = (set(MODULES) | {"cie10"}) - {"migrate"}
SERVICES = COMPONENTS | {"migrate", "manifest", "selected"}
RELEASE_TAG = re.compile(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?-[0-9a-f]{7,40}")
ROOT = Path(__file__).resolve().parents[1]


def manifest_images(path):
    content = Path(path).read_text()
    block = re.search(r"(?m)^image_tags\s*=\s*\{\s*\n([^{}]*)^\}", content)
    if not block:
        raise ValueError("No se encontro image_tags")
    pairs = re.findall(r'^\s*"([a-z0-9-]+)"\s*=\s*"([^"\n]+)"\s*$', block.group(1), re.M)
    images = dict(pairs)
    if len(pairs) != len(images) or set(images) != COMPONENTS | {"migrate"}:
        raise ValueError("El manifiesto debe contener exactamente los seis servicios")
    return images


def allowed_resources(service, migrate=False):
    if not isinstance(service, str):
        return set().union(*(allowed_resources(item) for item in service), allowed_resources("migrate") if migrate else set())
    if service == "manifest":
        return allowed_resources(COMPONENTS | {"migrate"})
    if service == "cie10":
        result = {"aws_ecs_task_definition.cie10", "aws_ecs_task_definition.cie10_indexer", "aws_scheduler_schedule.cie10_monthly"}
    else:
        module = MODULES[service]
        result = {f"module.{module}.aws_ecs_task_definition.this"}
        if service != "migrate":
            result.add(f"module.{module}.aws_ecs_service.this")
    if migrate:
        result.add("module.migrate.aws_ecs_task_definition.this")
    return result


def selected_services(args):
    if args.service == "selected":
        names = [item.strip() for item in args.components.split(",")]
        if names == ["all"]:
            selected = set(COMPONENTS)
        elif not names or len(names) != len(set(names)) or set(names) - COMPONENTS:
            raise ValueError("components requiere nombres unicos: api,frontend,pdf-worker,keycloak,cie10; o all")
        else:
            selected = set(names)
    else:
        if args.components:
            raise ValueError("components solo se usa con service=selected")
        selected = COMPONENTS | {"migrate"} if args.service == "manifest" else {args.service}
    if args.tag and (args.service in {"manifest", "selected"} or args.latest or args.resolved_tags):
        raise ValueError("tag solo se usa para un servicio individual, sin latest ni resolved_tags")
    if args.latest and (args.service in {"manifest", "migrate"} or args.resolved_tags):
        raise ValueError("latest no se combina con manifest, migrate ni resolved_tags; las migraciones son explicitas")
    if args.resolved_tags and args.service in {"manifest", "migrate"}:
        raise ValueError("resolved_tags solo fija versiones de componentes; usar migrate_tag para SQL")
    if args.migrate_tag and ("api" not in selected or args.service == "manifest"):
        raise ValueError("migrate_tag requiere seleccionar api; manifest ya incluye su migracion versionada")
    if args.service not in {"manifest", "selected"} and not (args.tag or args.latest or args.resolved_tags):
        raise ValueError("Indicar tag exacto o marcar latest")
    return selected


def ecr_images(service, tag=None):
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
    args = ["aws", "ecr", "describe-images", "--region", region, "--repository-name", "congenia/" + service]
    # La CLI pagina automaticamente. No truncar antes de ordenar por fecha.
    args += ["--image-ids", "imageTag=" + tag] if tag else ["--filter", "tagStatus=TAGGED"]
    return json.loads(command([*args, "--output", "json"]))["imageDetails"]


def latest_image(service):
    candidates = []
    for image in ecr_images(service):
        tags = sorted(tag for tag in image.get("imageTags", []) if RELEASE_TAG.fullmatch(tag))
        if not tags:
            continue
        pushed = image["imagePushedAt"]
        if isinstance(pushed, str):
            pushed = datetime.fromisoformat(pushed.replace("Z", "+00:00"))
            pushed = pushed.replace(tzinfo=pushed.tzinfo or timezone.utc).timestamp()
        for tag in tags:
            candidates.append((float(pushed), tag, image))
    if not candidates:
        raise ValueError(f"No hay imagenes con tag version-sha publicadas para {service}")
    newest = max(item[0] for item in candidates)
    winners = [item for item in candidates if item[0] == newest]
    if len(winners) != 1:
        raise ValueError(f"Ultima imagen ambigua para {service}; indicar un tag exacto")
    return winners[0][1], winners[0][2]


def resolved_images(args, selected):
    if args.resolved_tags:
        def unique_keys(pairs):
            result = dict(pairs)
            if len(result) != len(pairs):
                raise ValueError("resolved_tags contiene claves duplicadas")
            return result
        images = json.loads(args.resolved_tags, object_pairs_hook=unique_keys)
        if not isinstance(images, dict) or set(images) != selected:
            raise ValueError("resolved_tags debe ser un objeto JSON con exactamente los componentes elegidos")
    elif args.latest:
        images = {}
    elif args.service in {"manifest", "selected"}:
        manifest = manifest_images(ROOT / "envs/aws/images.tfvars")
        images = {name: manifest[name] for name in sorted(selected)}
    else:
        images = {args.service: args.tag}
    if args.migrate_tag:
        images["migrate"] = args.migrate_tag
    for tag in images.values():
        if not isinstance(tag, str) or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
            raise ValueError("Tag invalido")
    details = {}
    for service in sorted(selected | set(images)):
        if args.latest and service != "migrate":
            images[service], details[service] = latest_image(service)
        else:
            found = ecr_images(service, images[service])
            if len(found) != 1 or images[service] not in found[0].get("imageTags", []):
                raise ValueError(f"La imagen debe estar publicada en ECR: {service}")
            details[service] = found[0]
        print(service, images[service], details[service]["imageDigest"], flush=True)
    return images


def current_images(services):
    region, cluster = output("region"), output("ecs_cluster")
    prefix = cluster.removesuffix("-cluster")
    definitions = {}
    permanent = services & (COMPONENTS - {"cie10"})
    if permanent:
        names = [prefix + "-" + service for service in sorted(permanent)]
        result = json.loads(command(["aws", "ecs", "describe-services", "--region", region, "--cluster", cluster, "--services", *names, "--output", "json"]))
        states = {state["serviceName"]: state for state in result["services"]}
        if result.get("failures") or set(states) != set(names):
            raise ValueError("No se pudieron consultar todos los servicios elegidos en ECS")
        definitions.update({service: states[prefix + "-" + service]["taskDefinition"] for service in permanent})
    if "cie10" in services:
        schedule = json.loads(command(["aws", "scheduler", "get-schedule", "--region", region, "--name", prefix + "-cie10-monthly", "--group-name", "default", "--query", "Target.EcsParameters.TaskDefinitionArn", "--output", "json"]))
        definitions["cie10"] = schedule
    if "migrate" in services:
        definitions["migrate"] = output("migrate_task_definition")
    images = {}
    for service, definition in sorted(definitions.items()):
        containers = json.loads(command(["aws", "ecs", "describe-task-definition", "--region", region, "--task-definition", definition, "--query", "taskDefinition.containerDefinitions[].{name:name,image:image}", "--output", "json"]))
        image = next(container["image"] for container in containers if container["name"] == service)
        match = re.fullmatch(r"[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/congenia/" + re.escape(service) + r":([A-Za-z0-9_][A-Za-z0-9_.-]{0,127})", image)
        images[service] = match[1] if match else "imagen por digest o externa"
    return images


def release_summary(images, current):
    lines = ["### Imagenes resueltas para esta ejecucion", "", "| Componente | Actual en ECS / scheduler | Seleccionada | Imagen |", "|---|---|---|---|"]
    for service, tag in sorted(images.items()):
        action = "sin cambio" if current[service] == tag else "actualizar"
        lines.append(f"| {service} | `{current[service]}` | `{tag}` | {action} |")
    pinned = {name: tag for name, tag in sorted(images.items()) if name != "migrate"}
    if pinned:
        lines += ["", "Para repetir estas versiones, desmarcar latest y copiar en resolved_tags:", "", "```json", json.dumps(pinned, sort_keys=True), "```"]
    if "migrate" in images:
        lines += ["", f"Migracion explicita: `{images['migrate']}`. Se ejecutara antes de desplegar; la tabla muestra su definicion registrada, no confirma que el SQL ya se haya aplicado."]
    else:
        lines += ["", "Sin migracion: no se ejecutara SQL. Si la API requiere esquema nuevo, indicar migrate_tag compatible."]
    lines += ["", "La tabla compara imagenes; el plan tambien comprueba revisiones y configuracion permitida.", ""]
    print("\n".join(lines), flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write("\n".join(lines))


def guard_plan(plan, service, migrate=False, runtime_config=False):
    allowed = allowed_resources(service, migrate)
    changes = []
    for resource in plan.get("resource_changes", []):
        if resource["mode"] != "managed" or resource["change"]["actions"] == ["no-op"]:
            continue
        address, change = resource["address"], resource["change"]
        if address not in allowed:
            raise ValueError(f"Cambio ajeno a la release: {address}")
        before, after = change.get("before"), change.get("after")
        if not before or not after:
            raise ValueError(f"Creacion/eliminacion inesperada: {address}")
        if resource["type"] == "aws_ecs_task_definition":
            if change["actions"] not in [["delete", "create"], ["create", "delete"], ["update"]]:
                raise ValueError(f"Accion no permitida: {address}")
            for key in ("family", "cpu", "memory", "network_mode", "execution_role_arn", "task_role_arn", "requires_compatibilities", "runtime_platform", "volume", "ephemeral_storage", "pid_mode", "ipc_mode", "proxy_configuration", "tags"):
                if key == "task_role_arn" and change.get("after_unknown", {}).get(key):
                    raise ValueError(f"Configuracion ajena a una imagen: {address}.{key}")
                # El provider representa modos y task role omitidos como ""
                # al leer y null al planear una revision nueva: misma ausencia.
                if key in {"pid_mode", "ipc_mode", "task_role_arn"} and before.get(key) in (None, "") and after.get(key) in (None, ""):
                    continue
                if before.get(key) != after.get(key):
                    raise ValueError(f"Configuracion ajena a una imagen: {address}.{key}")
            containers = []
            for value in (before, after):
                parsed = json.loads(value["container_definitions"])
                for container in parsed:
                    container.pop("image", None)
                    if runtime_config:
                        container.pop("environment", None)
                    # ECS devuelve estas listas vacias aunque no se enviaran.
                    for key in ("mountPoints", "volumesFrom", "systemControls", "portMappings"):
                        if container.get(key) in (None, []):
                            container.pop(key, None)
                containers.append(parsed)
            if containers[0] != containers[1]:
                raise ValueError(f"Cambio de contenedor distinto de imagen: {address}")
        elif resource["type"] == "aws_ecs_service":
            if change["actions"] != ["update"]:
                raise ValueError(f"Reemplazo de servicio no permitido: {address}")
            for key in before:
                if key not in {"task_definition", "id"} and before.get(key) != after.get(key):
                    raise ValueError(f"Cambio de servicio distinto de revision: {address}.{key}")
        elif resource["type"] == "aws_scheduler_schedule":
            if change["actions"] != ["update"]:
                raise ValueError("El calendario solo admite actualizar su revision")
            values = copy.deepcopy([before, after])
            for value in values:
                value.pop("id", None)
                value.pop("arn", None)
                for target in value["target"]:
                    for ecs in target["ecs_parameters"]:
                        ecs.pop("task_definition_arn", None)
            if values[0] != values[1]:
                raise ValueError("Cambio de calendario distinto de revision")
        else:
            raise ValueError(f"Tipo de recurso no permitido: {resource['type']}")
        changes.append((address, change["actions"]))
    return changes


def command(args, capture=True):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=capture)
    if result.returncode:
        # Solo metadatos de errores: nunca imprimir stdout del plan, tfstate,
        # respuestas de Secrets Manager ni argumentos con valores sensibles.
        details = failure_diagnostics(result.stdout, result.stderr)
        stage = next((arg for arg in args[1:] if arg in {"init", "plan", "apply", "show", "output"}), "comando")
        raise RuntimeError(f"Fallo {args[0]} {stage} (codigo {result.returncode}); etapa detenida. {details}")
    return result.stdout if capture else ""


def failure_diagnostics(stdout, stderr):
    text = (stdout or "") + "\n" + (stderr or "")
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    denied = sorted(set(re.findall(r"not authorized to perform:\s*([a-z0-9-]+:[A-Za-z0-9*]+)", text)))
    operations = sorted(set(re.findall(r"operation error ([A-Za-z0-9 ]+):\s*([A-Za-z0-9]+)", text)))
    details = []
    if denied:
        details.append("Permisos faltantes: " + ", ".join(denied))
    if operations:
        details.append("Operaciones AWS: " + ", ".join(service + ":" + operation for service, operation in operations))
    if "Error acquiring the state lock" in text:
        details.append("No se pudo adquirir el bloqueo del estado Terraform")
    if not details:
        # Los titulos del core identifican errores de configuracion sin incluir
        # lineas de HCL, valores, ARN ni payloads devueltos por un provider.
        core_errors = {
            "Unsupported argument", "Unsupported attribute", "Reference to undeclared resource",
            "Invalid function argument", "Invalid value for input variable", "Missing required argument",
            "Inconsistent dependency lock file", "Invalid provider configuration", "Error loading state",
        }
        titles = sorted(core_errors.intersection(re.findall(r"(?m)^Error:\s*([^\n]+)", text)))
        details.extend(titles)
    return "; ".join(details) or "No hay metadatos reconocidos; revisar eventos de AWS o diagnosticos de Terraform de forma privada"


def tf(*args):
    return command(["terraform", "-chdir=envs/aws", *args])


def output(name):
    return tf("output", "-raw", name).strip()


def plan_and_apply(directory, service, migrate, apply, target=False, runtime_config=False):
    path = str(Path(directory, "release.tfplan"))
    args = ["plan", "-input=false", "-lock-timeout=5m", "-no-color", "-var-file=images.tfvars", "-var-file=features.tfvars", "-var=enable_services=true", "-out=" + path]
    if target:
        args.append("-target=module.migrate")
    tf(*args)
    os.chmod(path, 0o600)
    plan = json.loads(tf("show", "-json", path))
    changes = guard_plan(plan, service, migrate, runtime_config)
    for address, actions in changes:
        print(address, "/".join(actions), flush=True)
    print(f"Plan validado: {len(changes)} cambios permitidos", flush=True)
    if apply:
        tf("apply", "-input=false", "-no-color", path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--service", choices=sorted(SERVICES), required=True)
    parser.add_argument("--tag", default="")
    parser.add_argument("--components", default="")
    parser.add_argument("--latest", action="store_true")
    parser.add_argument("--resolved-tags", default="")
    parser.add_argument("--migrate-tag", default="")
    parser.add_argument("--runtime-config", action="store_true")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        selected = selected_services(args)
        images = resolved_images(args, selected)
    except ValueError as error:
        parser.error(str(error))
    # Mantener el contrato anterior de los modos individuales/manifest.
    scope = selected if args.service == "selected" else args.service
    update = runpy.run_path(str(ROOT / "scripts/bump-image-tag.py"))["actualizar"]
    for service, tag in images.items():
        update(ROOT / "envs/aws/images.tfvars", service, tag)
    tf("fmt", "images.tfvars")
    tf("init", "-input=false")
    release_summary(images, current_images(set(images)))
    migration = "migrate" in images
    with tempfile.TemporaryDirectory(prefix="congenia-release-") as directory:
        # Revisar TODO antes de aplicar SQL o cambiar definiciones.
        plan_and_apply(directory, scope, migration, False, runtime_config=args.runtime_config)
        if not args.apply:
            print("Vista previa terminada; sin aplicar cambios en AWS ni publicar commits")
            return
        if migration:
            plan_and_apply(directory, "migrate", False, True, target=True, runtime_config=args.runtime_config)
            command(["bash", "scripts/migrate.sh", "envs/aws"], capture=False)
        plan_and_apply(directory, scope, migration, True, runtime_config=args.runtime_config)
    permanent = {"api", "frontend", "pdf-worker", "keycloak"}
    targets = sorted(selected & permanent)
    if targets:
        region, cluster = output("region"), output("ecs_cluster")
        prefix = cluster.removesuffix("-cluster")
        names = [prefix + "-" + service for service in targets]
        command(["aws", "ecs", "wait", "services-stable", "--region", region, "--cluster", cluster, "--services", *names])
        states = json.loads(command(["aws", "ecs", "describe-services", "--region", region, "--cluster", cluster, "--services", *names, "--output", "json"]))["services"]
        states = {state["serviceName"]: state for state in states}
        expected = json.loads(tf("output", "-json", "release_task_definitions"))
        for service in targets:
            state = states[prefix + "-" + service]
            if state["taskDefinition"] != expected[service] or len(state["deployments"]) != 1 or state["runningCount"] != state["desiredCount"] or state["desiredCount"] < 1:
                raise RuntimeError(f"ECS no estabilizo la revision solicitada: {service}")
    command(["make", "smoke", "ENV=aws"], capture=False)
    if os.environ.get("CONGENIA_VERIFIED_RELEASE_FILE"):
        verified = Path(os.environ["CONGENIA_VERIFIED_RELEASE_FILE"])
        verified.write_text(json.dumps(images, sort_keys=True) + "\n")
        verified.chmod(0o600)
    print("Release verificada; el workflow puede registrar el manifiesto", flush=True)


if __name__ == "__main__":
    main()
