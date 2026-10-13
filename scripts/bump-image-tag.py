"""Actualizar una version publicada sin modificar las demas imagenes."""
import pathlib
import re

SERVICIOS = {"api", "frontend", "pdf-worker", "cie10", "keycloak", "migrate"}


def actualizar(archivo, servicio, tag):
    if servicio not in SERVICIOS:
        raise ValueError("Servicio desconocido")
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
        raise ValueError("Tag ECR invalido")
    ruta = pathlib.Path(archivo)
    texto = ruta.read_text()
    mapa = re.search(r"(?m)^image_tags\s*=\s*\{\s*\n(?P<body>[^{}]*)^\}", texto)
    if not mapa:
        raise ValueError("No se encontro un unico mapa image_tags valido")
    cuerpo = mapa.group("body")
    patron = re.compile(r'^(\s*"%s"\s*=\s*)"[^"]*"' % re.escape(servicio), re.M)
    nuevo, n = patron.subn(lambda m: '%s"%s"' % (m.group(1), tag), cuerpo)
    if n > 1:
        raise ValueError("El servicio aparece mas de una vez")
    if n == 0:
        nuevo = cuerpo + f'  "{servicio}" = "{tag}"\n'
    ruta.write_text(texto[:mapa.start("body")] + nuevo + texto[mapa.end("body"):])
