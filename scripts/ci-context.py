"""Preparar el backend y las variables de Terraform para GitHub Actions."""
import json
import os
from pathlib import Path
import re
import shlex


def settings(environment):
    names = ("AWS_ACCOUNT_ID", "AWS_DEPLOY_ROLE_ARN", "AWS_REGION", "TF_STATE_BUCKET", "TF_NAME_PREFIX", "TF_DOMAIN_NAME")
    missing = [name for name in names if not environment.get(name)]
    if missing:
        raise ValueError("Configurar variables del repositorio: " + ", ".join(missing))
    values = {name: environment[name] for name in names}
    if not re.fullmatch(r"[0-9]{12}", values["AWS_ACCOUNT_ID"]):
        raise ValueError("AWS_ACCOUNT_ID debe tener 12 digitos")
    role = re.fullmatch(r"arn:aws:iam::([0-9]{12}):role/[A-Za-z0-9+=,.@_/-]+", values["AWS_DEPLOY_ROLE_ARN"])
    if not role or role[1] != values["AWS_ACCOUNT_ID"]:
        raise ValueError("AWS_DEPLOY_ROLE_ARN debe pertenecer a AWS_ACCOUNT_ID")
    if not re.fullmatch(r"[a-z]{2}(?:-[a-z0-9]+)+-[0-9]", values["AWS_REGION"]):
        raise ValueError("AWS_REGION no es una region valida")
    bucket = values["TF_STATE_BUCKET"]
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket) or re.fullmatch(r"[0-9.]+", bucket):
        raise ValueError("TF_STATE_BUCKET no es un nombre de bucket valido")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,14}", values["TF_NAME_PREFIX"]):
        raise ValueError("TF_NAME_PREFIX requiere 1 a 15 caracteres minusculos, numeros o guiones")
    domain = values["TF_DOMAIN_NAME"]
    if len(domain) > 253 or not re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", domain):
        raise ValueError("TF_DOMAIN_NAME no es un dominio valido")
    return values


def prepare(environment):
    values = settings(environment)
    for name in ("RUNNER_TEMP", "GITHUB_ENV"):
        if not environment.get(name) or any(c in environment[name] for c in "\n\r\0"):
            raise ValueError("Define " + name + " para preparar el contexto de Actions")
    temporary = Path(environment["RUNNER_TEMP"]).resolve()
    temporary.mkdir(parents=True, exist_ok=True)
    backend = temporary / "congenia-backend.hcl"
    backend.write_text(
        "bucket = " + json.dumps(values["TF_STATE_BUCKET"]) + "\n"
        "region = " + json.dumps(values["AWS_REGION"]) + "\n"
        "allowed_account_ids = " + json.dumps([values["AWS_ACCOUNT_ID"]]) + "\n",
        encoding="utf-8",
    )
    backend.chmod(0o600)
    exports = {
        "AWS_DEFAULT_REGION": values["AWS_REGION"],
        "TF_VAR_region": values["AWS_REGION"],
        "TF_VAR_name_prefix": values["TF_NAME_PREFIX"],
        "TF_VAR_domain_name": values["TF_DOMAIN_NAME"],
        "TF_DATA_DIR": str(temporary / "terraform-data-aws"),
        "TF_CLI_ARGS_init": "-reconfigure -backend-config=" + shlex.quote(str(backend)),
    }
    with Path(environment["GITHUB_ENV"]).open("a", encoding="utf-8") as handle:
        handle.write("".join(f"{key}={value}\n" for key, value in exports.items()))
    return exports


if __name__ == "__main__":
    try:
        prepare(os.environ)
    except ValueError as error:
        raise SystemExit(str(error))
    print("Contexto Terraform preparado para cuenta, backend, prefijo y dominio del repositorio.")
