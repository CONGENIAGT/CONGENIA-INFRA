# =============================================================================
# Configuracion del entorno local.
#
# Imagenes construidas desde los repos de servicio con `make images`.
# NO se usa xavierlopez25/congenia: ese repositorio de Docker Hub es PRIVADO
# (un pull anonimo responde 401) y por tanto MiniStack no puede halarlo.
# MiniStack necesita imagenes locales accesibles por Docker.
# =============================================================================

image_api        = "congenia/api:local"
image_frontend   = "congenia/frontend:local"
image_pdf_worker = "congenia/pdf-worker:local"
