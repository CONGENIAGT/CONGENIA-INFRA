#!/usr/bin/env python3
"""
Reconciliacion del ALB en el entorno local (MiniStack).

Terraform deja el stack descrito correctamente, pero MiniStack no ejecuta dos
integraciones que en AWS real son nativas. Este script las cierra:

  1. CONDICIONES DE LAS REGLAS
     El provider de AWS v6 manda las condiciones como
     `Conditions.member.N.PathPatternConfig.Values.member.M`.
     MiniStack solo lee la forma antigua `Conditions.member.N.Values.member.M`
     (ministack/services/alb.py, _parse_conditions), asi que guarda la regla
     con la lista de patrones VACIA y ningun path llega a hacer match: todo el
     trafico cae al target por defecto. Aqui se reescribe cada regla con el
     formato que MiniStack si entiende.

  2. REGISTRO DE TARGETS
     El bloque `load_balancer` de `aws_ecs_service` no puebla el target group.
     Aqui se registran las IPs reales de los contenedores de cada tarea.

Ninguno de los dos pasos hace falta en AWS real.
"""

import json
import subprocess
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ENDPOINT = "http://localhost:4566"
ELB_NS = "{http://elasticloadbalancing.amazonaws.com/doc/2015-12-01/}"


def ecs_call(action, payload):
    req = urllib.request.Request(
        ENDPOINT + "/",
        data=json.dumps(payload).encode(),
        headers={
            "X-Amz-Target": f"AmazonEC2ContainerServiceV20141113.{action}",
            "Content-Type": "application/x-amz-json-1.1",
            "Authorization": (
                "AWS4-HMAC-SHA256 Credential=test/20260101/us-east-1/ecs/aws4_request"
            ),
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.load(resp)


def elb_call(action, params):
    query = [("Action", action), ("Version", "2015-12-01")] + params
    url = ENDPOINT + "/?" + urllib.parse.urlencode(query)
    with urllib.request.urlopen(url, timeout=15) as resp:
        return ET.fromstring(resp.read())


def tf_output(tfdir, name):
    out = subprocess.run(
        ["terraform", "output", "-json", name],
        cwd=tfdir, capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


def container_ip(name):
    out = subprocess.run(
        ["docker", "inspect", "-f",
         "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", name],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        return None
    ips = out.stdout.split()
    return ips[0] if ips else None


def fix_rules(rule_arns, routes):
    """Reescribe las condiciones path-pattern en el formato legacy."""
    print("Reglas del listener:")
    for service, arn in rule_arns.items():
        paths = routes.get(service, [])
        if not paths:
            continue

        params = [("RuleArn", arn), ("Conditions.member.1.Field", "path-pattern")]
        for i, path in enumerate(paths, start=1):
            params.append((f"Conditions.member.1.Values.member.{i}", path))

        elb_call("ModifyRule", params)
        print(f"  + {service}: {', '.join(paths)}")


def register_targets(cluster, prefix, target_groups):
    """Registra la IP de cada tarea ECS en su target group."""
    print("Targets del ALB:")
    failures = 0

    for service, tg_arn in target_groups.items():
        full_name = f"{prefix}-{service}"

        root = elb_call("DescribeTargetGroups", [("TargetGroupArns.member.1", tg_arn)])
        port_el = root.find(f".//{ELB_NS}Port")
        port = int(port_el.text) if port_el is not None else 80

        tasks = ecs_call("ListTasks", {
            "cluster": cluster, "serviceName": full_name,
        }).get("taskArns", [])

        if not tasks:
            print(f"  ! {full_name}: sin tareas en ejecucion")
            failures += 1
            continue

        for task_arn in tasks:
            task_id = task_arn.rsplit("/", 1)[-1]
            # MiniStack nombra el contenedor ministack-ecs-<8 chars>-<contenedor>
            guess = f"ministack-ecs-{task_id[:8]}-{service}"
            ip = container_ip(guess)

            if not ip:
                print(f"  ! {full_name}: no se hallo el contenedor {guess}")
                failures += 1
                continue

            elb_call("RegisterTargets", [
                ("TargetGroupArn", tg_arn),
                ("Targets.member.1.Id", ip),
                ("Targets.member.1.Port", str(port)),
            ])
            print(f"  + {full_name}: {ip}:{port}")

    return failures


def main():
    tfdir = sys.argv[1] if len(sys.argv) > 1 else "envs/local"

    cluster = subprocess.run(
        ["terraform", "output", "-raw", "ecs_cluster"],
        cwd=tfdir, capture_output=True, text=True, check=True,
    ).stdout.strip()
    prefix = cluster.removesuffix("-cluster")

    fix_rules(tf_output(tfdir, "alb_rule_arns"), tf_output(tfdir, "alb_routes"))
    failures = register_targets(cluster, prefix, tf_output(tfdir, "target_group_arns"))

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
