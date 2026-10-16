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
SERVICES = set(MODULES) | {"cie10"}
ROOT = Path(__file__).resolve().parents[1]


def allowed_resources(service, migrate=False):
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


def guard_plan(plan, service, migrate=False):
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
        # Terraform puede incluir valores sensibles. No subir planes ni su JSON.
        raise RuntimeError(f"Fallo {args[0]} (codigo {result.returncode}); etapa detenida")
    return result.stdout if capture else ""


def tf(*args):
    return command(["terraform", "-chdir=envs/aws", *args])


def output(name):
    return tf("output", "-raw", name).strip()


def plan_and_apply(directory, service, migrate, apply, target=False):
    path = str(Path(directory, "release.tfplan"))
    args = ["plan", "-input=false", "-lock-timeout=5m", "-no-color", "-var-file=images.tfvars", "-var-file=features.tfvars", "-var=enable_services=true", "-out=" + path]
    if target:
        args.append("-target=module.migrate")
    tf(*args)
    os.chmod(path, 0o600)
    plan = json.loads(tf("show", "-json", path))
    changes = guard_plan(plan, service, migrate)
    for address, actions in changes:
        print(address, "/".join(actions), flush=True)
    print(f"Plan validado: {len(changes)} cambios permitidos", flush=True)
    if apply:
        tf("apply", "-input=false", "-no-color", path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--service", choices=sorted(SERVICES), required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--migrate-tag", default="")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.migrate_tag and args.service != "api":
        parser.error("migrate-tag solo acompana una release de api")
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
    migration = args.service == "migrate" or bool(args.migrate_tag)
    with tempfile.TemporaryDirectory(prefix="congenia-release-") as directory:
        # Revisar TODO antes de aplicar SQL o cambiar definiciones.
        plan_and_apply(directory, args.service, migration, False)
        if not args.apply:
            print("Vista previa terminada; sin aplicar cambios en AWS ni publicar commits")
            return
        if migration:
            plan_and_apply(directory, "migrate", False, True, target=True)
            command(["bash", "scripts/migrate.sh", "envs/aws"], capture=False)
        plan_and_apply(directory, args.service, migration, True)
    if args.service in {"api", "frontend", "pdf-worker", "keycloak"}:
        region, cluster = output("region"), output("ecs_cluster")
        prefix = cluster.removesuffix("-cluster")
        service = prefix + "-" + args.service
        command(["aws", "ecs", "wait", "services-stable", "--region", region, "--cluster", cluster, "--services", service])
        state = json.loads(command(["aws", "ecs", "describe-services", "--region", region, "--cluster", cluster, "--services", service, "--output", "json"]))["services"][0]
        expected = tf("output", "-json", "release_task_definitions")
        expected = json.loads(expected)[args.service]
        if state["taskDefinition"] != expected or len(state["deployments"]) != 1 or state["runningCount"] != state["desiredCount"] or state["desiredCount"] < 1:
            raise RuntimeError("ECS no estabilizo la revision solicitada")
    command(["make", "smoke", "ENV=aws"], capture=False)
    print("Release verificada; el workflow puede registrar el manifiesto", flush=True)


if __name__ == "__main__":
    main()
