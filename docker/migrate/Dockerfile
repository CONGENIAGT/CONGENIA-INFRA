# Imagen de un solo uso para cargar el esquema en RDS.
#
# Los .sql se hornean en la imagen a proposito. La version manual de la prueba
# los descargaba al arrancar con `apk add curl`, lo que ataba la tarea al NAT
# Gateway y a que una URL siguiera viva. Horneados, la tarea solo necesita
# alcanzar ECR (ya hay endpoints de interface) y RDS.
#
# El contexto de build es este directorio; `make migrate-image` copia antes los
# .sql desde CONGENIA-M1-SERVER/db/init a ./sql (ver Makefile).
FROM postgres:16-alpine

COPY sql/ /sql/
COPY entrypoint.sh /usr/local/bin/migrate

RUN chmod +x /usr/local/bin/migrate

# La imagen oficial arranca un servidor; aqui solo queremos el cliente.
ENTRYPOINT ["/usr/local/bin/migrate"]
