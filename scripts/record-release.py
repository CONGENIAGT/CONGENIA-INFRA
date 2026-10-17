"""Registrar solo las imagenes verificadas desde un worktree limpio."""
from pathlib import Path
import argparse
import json
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = "envs/aws/images.tfvars"
READ_IMAGES = runpy.run_path(str(ROOT / "scripts/deploy-release.py"))["manifest_images"]
UPDATE_IMAGE = runpy.run_path(str(ROOT / "scripts/bump-image-tag.py"))["actualizar"]


def git(repo, *args):
    result = subprocess.run(["git", *args], cwd=repo, text=True, capture_output=True)
    if result.returncode:
        # No volcar diffs, configuracion de autenticacion ni otros archivos.
        raise RuntimeError(f"Git {args[0]} fallo; registro pendiente. Comprobar AWS antes de repetir el despliegue")
    return result.stdout.strip()


def record_release(repo=ROOT, verified=None):
    repo = Path(repo)
    desired = READ_IMAGES(repo / MANIFEST)
    with tempfile.TemporaryDirectory(prefix="congenia-record-release-") as directory:
        base_file = Path(directory, "base.tfvars")
        base_file.write_text(git(repo, "show", "HEAD:" + MANIFEST) + "\n")
        base = READ_IMAGES(base_file)
        if verified is not None:
            if not isinstance(verified, dict) or not verified or any(name not in desired or tag != desired[name] for name, tag in verified.items()):
                raise ValueError("Los tags verificados no coinciden con el manifiesto del despliegue")
            changed = verified
        else:
            changed = {name: tag for name, tag in desired.items() if base[name] != tag}
        if not changed:
            print("Sin cambios de tags para registrar")
            return False
        git(repo, "fetch", "origin", "master")
        worktree = Path(directory, "worktree")
        try:
            git(repo, "worktree", "add", "--detach", str(worktree), "origin/master")
            current = READ_IMAGES(worktree / MANIFEST)
            conflicts = sorted(name for name, tag in changed.items() if current[name] not in {base[name], tag})
            if conflicts:
                raise RuntimeError("Conflicto de tags en master: " + ", ".join(conflicts) + "; comprobar AWS antes de registrar")
            for name, tag in sorted(changed.items()):
                if current[name] != tag:
                    UPDATE_IMAGE(worktree / MANIFEST, name, tag)
            if not git(worktree, "diff", "--name-only", "--", MANIFEST):
                print("Los tags verificados ya estan registrados en master")
                return False
            git(worktree, "add", "--", MANIFEST)
            message = "chore(release): " + ", ".join(name + " " + tag for name, tag in sorted(changed.items())) + " [skip ci]"
            git(worktree, "-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com", "commit", "-m", message)
            # Sin force ni rebase del workspace del deploy. Si master avanza
            # entre fetch y push, Git rechaza el push y se revisa el registro.
            git(worktree, "push", "origin", "HEAD:master")
            print("Tags verificados registrados en master")
            return True
        finally:
            subprocess.run(["git", "worktree", "remove", "--force", str(worktree)], cwd=repo, capture_output=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verified-file", required=True)
    args = parser.parse_args()
    record_release(verified=json.loads(Path(args.verified_file).read_text()))
