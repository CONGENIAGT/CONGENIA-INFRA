# Configuracion no secreta; credenciales almacenadas en Secrets Manager.
# Reporteria encendida (2026-10-31): los cuatro secretos reporting-* deben tener
# valor en Secrets Manager antes del apply; sin version, la tarea API no arranca.
# La base SIGSA vive en Neon (simula la del cliente); la de CONGENIA es RDS.
enable_reporting                   = true
enable_cie10_schedule              = false
llm_model                          = "gpt-6-luna"
llm_reasoning_effort               = "low"
reporting_conversation_ttl_seconds = 1800
reporting_conversation_max_turns   = 8
agent_prompt_version               = "agent-reporting-v1"
reporting_dataset_version          = "sigsa-2026-10"
reporting_schema_version           = "reporting-v1"
cie10_max_records                  = 20
cie10_repair_attempts              = 2
cie10_rag_version                  = null
reporting_statement_timeout_ms     = 5000
