"""Desplegar una imagen publicada; limitar Terraform a la release solicitada."""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile

MODULES = {"api": "api", "frontend": "frontend", "pdf-worker": "pdf_worker", "keycloak": "keycloak", "migrate": "migrate"}
SERVICES = set(MODULES) | {"cie10", "manifest"}
ROOT = Path(__file__).resolve().parents[1]


def manifest_images(path):
    content = Path(path).read_text()
    block = re.search(r"(?m)^image_tags\s*=\s*\{\s*\n([^{}]*)^\}", content)
    if not block:
        raise ValueError("No se encontro image_tags")
    pairs = re.findall(r'^\s*"([a-z0-9-]+)"\s*=\s*"([^"\n]+)"\s*$', block.group(1), re.M)
    images = dict(pairs)
    if len(pairs) != len(images) or set(images) != SERVICES - {"manifest"}:
        raise ValueError("El manifiesto debe contener exactamente los seis servicios")
    return images


def allowed_resources(service, migrate=False):
    if service == "manifest":
        return set().union(*(allowed_resources(item) for item in SERVICES - {"manifest"}))
    if service == "cie10":
        result = {"aws_ecs_task_definition.cie10", "aws_scheduler_schedule.cie10_monthly"}
    else:
        module = MODULES[service]
        result = {f"module.{module}.aws_ecs_task_definition.this"}
        if service != "migrate":
            result.add(f"module.{module}.aws_ecs_service.this")
    if migrate:
        result.add("module.migrate.aws_ecs_task_definition.this")
    return result


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
                # El provider representa los modos omitidos como "" al leer
                # y null al planear una revision nueva. Son el mismo default.
                if key in {"pid_mode", "ipc_mode"} and before.get(key) in (None, "") and after.get(key) in (None, ""):
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
    parser.add_argument("--migrate-tag", default="")
    parser.add_argument("--runtime-config", action="store_true")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.migrate_tag and args.service != "api":
        parser.error("migrate-tag solo acompana una release de api")
    if args.service == "manifest":
        if args.tag:
            parser.error("manifest usa los tags versionados; dejar tag vacio")
        images = manifest_images(ROOT / "envs/aws/images.tfvars")
    else:
        if not args.tag:
            parser.error("Es obligatorio indicar tag")
        images = {args.service: args.tag}
    if args.migrate_tag:
        images["migrate"] = args.migrate_tag
    for service, tag in images.items():
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
            parser.error("Tag invalido")
        result = json.loads(command(["aws", "ecr", "describe-images", "--region", "us-east-1", "--repository-name", "congenia/" + service, "--image-ids", "imageTag=" + tag, "--output", "json"]))
        if len(result.get("imageDetails", [])) != 1:
            raise ValueError("La imagen debe estar publicada en ECR")
        print(service, tag, result["imageDetails"][0]["imageDigest"], flush=True)
    update = runpy.run_path(str(ROOT / "scripts/bump-image-tag.py"))["actualizar"]
    for service, tag in images.items():
        update(ROOT / "envs/aws/images.tfvars", service, tag)
    tf("fmt", "images.tfvars")
    tf("init", "-input=false")
    migration = args.service in {"migrate", "manifest"} or bool(args.migrate_tag)
    with tempfile.TemporaryDirectory(prefix="congenia-release-") as directory:
        # Revisar TODO antes de aplicar SQL o cambiar definiciones.
        plan_and_apply(directory, args.service, migration, False, runtime_config=args.runtime_config)
        if not args.apply:
            print("Vista previa terminada; sin aplicar cambios en AWS ni publicar commits")
            return
        if migration:
            plan_and_apply(directory, "migrate", False, True, target=True, runtime_config=args.runtime_config)
            command(["bash", "scripts/migrate.sh", "envs/aws"], capture=False)
        plan_and_apply(directory, args.service, migration, True, runtime_config=args.runtime_config)
    permanent = {"api", "frontend", "pdf-worker", "keycloak"}
    targets = sorted(permanent if args.service == "manifest" else {args.service} & permanent)
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
    print("Release verificada; el workflow puede registrar el manifiesto", flush=True)


if __name__ == "__main__":
    main()
