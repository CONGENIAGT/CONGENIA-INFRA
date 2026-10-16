import copy
import json
import pathlib
import runpy
import tempfile
import unittest
from unittest import mock

MODULE = runpy.run_path(str(pathlib.Path(__file__).parents[1] / "scripts/deploy-release.py"))
GUARD = MODULE["guard_plan"]
MAIN = MODULE["main"]


def task(module="api"):
    before = {"family": "congenia-prod-" + module, "container_definitions": json.dumps([{"name": module, "image": "ecr/old", "environment": [{"name": "X", "value": "existing"}]}])}
    after = copy.deepcopy(before)
    after["container_definitions"] = after["container_definitions"].replace("ecr/old", "ecr/new")
    return {"mode": "managed", "type": "aws_ecs_task_definition", "address": f"module.{module}.aws_ecs_task_definition.this", "change": {"actions": ["delete", "create"], "before": before, "after": after}}


class ReleaseGuardTests(unittest.TestCase):
    def test_image_replacement_is_allowed_without_treating_it_as_data_destruction(self):
        self.assertEqual(len(GUARD({"resource_changes": [task()]}, "api")), 1)

    def test_api_and_optional_migration_can_be_planned_together(self):
        plan = {"resource_changes": [task(), task("migrate")]}
        self.assertEqual(len(GUARD(plan, "api", True)), 2)
        with self.assertRaises(ValueError): GUARD(plan, "api")

    def test_provider_empty_modes_equal_omitted_defaults_but_not_host_mode(self):
        resource = task()
        resource["change"]["before"].update(pid_mode="", ipc_mode="")
        resource["change"]["after"].update(pid_mode=None, ipc_mode=None)
        self.assertEqual(len(GUARD({"resource_changes": [resource]}, "api")), 1)
        resource["change"]["after"]["pid_mode"] = "host"
        with self.assertRaises(ValueError): GUARD({"resource_changes": [resource]}, "api")

    def test_ecs_empty_lists_equal_omitted_fields_but_real_mounts_are_rejected(self):
        resource = task()
        before = json.loads(resource["change"]["before"]["container_definitions"])
        before[0].update(mountPoints=[], volumesFrom=[], systemControls=[], portMappings=[])
        resource["change"]["before"]["container_definitions"] = json.dumps(before)
        self.assertEqual(len(GUARD({"resource_changes": [resource]}, "api")), 1)
        after = json.loads(resource["change"]["after"]["container_definitions"])
        after[0]["mountPoints"] = [{"sourceVolume": "new", "containerPath": "/data"}]
        resource["change"]["after"]["container_definitions"] = json.dumps(after)
        with self.assertRaises(ValueError): GUARD({"resource_changes": [resource]}, "api")

    def test_database_network_and_other_service_changes_are_rejected(self):
        for address in ["module.data.aws_db_instance.postgres", "module.network.aws_vpc.this", "module.frontend.aws_ecs_task_definition.this"]:
            resource = task()
            resource["address"] = address
            with self.assertRaises(ValueError): GUARD({"resource_changes": [resource]}, "api")

    def test_task_deletion_and_role_or_environment_changes_are_rejected(self):
        for field, value in [("actions", ["delete"]), ("role", "other-role"), ("environment", "changed")]:
            resource = task()
            if field == "actions": resource["change"][field] = value
            elif field == "role": resource["change"]["after"]["execution_role_arn"] = value
            else:
                resource["change"]["after"]["container_definitions"] = resource["change"]["after"]["container_definitions"].replace("existing", value)
            with self.assertRaises(ValueError): GUARD({"resource_changes": [resource]}, "api")

    def test_service_revision_is_allowed_but_scaling_is_rejected(self):
        before = {"desired_count": 1, "task_definition": "old", "network_configuration": [{"subnets": ["private"]}]}
        after = copy.deepcopy(before)
        after["task_definition"] = None  # Revision calculada durante apply.
        resource = {"mode": "managed", "type": "aws_ecs_service", "address": "module.api.aws_ecs_service.this", "change": {"actions": ["update"], "before": before, "after": after}}
        self.assertEqual(len(GUARD({"resource_changes": [resource]}, "api")), 1)
        resource["change"]["after"]["desired_count"] = 0
        with self.assertRaises(ValueError): GUARD({"resource_changes": [resource]}, "api")

    def test_cie10_schedule_can_change_revision_but_not_calendar_or_state(self):
        before = {"state": "ENABLED", "schedule_expression": "monthly", "target": [{"ecs_parameters": [{"task_definition_arn": "old"}]}]}
        after = copy.deepcopy(before)
        after["target"][0]["ecs_parameters"][0]["task_definition_arn"] = None
        resource = {"mode": "managed", "type": "aws_scheduler_schedule", "address": "aws_scheduler_schedule.cie10_monthly", "change": {"actions": ["update"], "before": before, "after": after}}
        self.assertEqual(len(GUARD({"resource_changes": [resource]}, "cie10")), 1)
        resource["change"]["after"]["state"] = "DISABLED"
        with self.assertRaises(ValueError): GUARD({"resource_changes": [resource]}, "cie10")


class ReleaseOrderingTests(unittest.TestCase):
    def run_release(self, apply):
        plans, commands = [], []

        def command(args, capture=True):
            commands.append(args)
            if args[:3] == ["aws", "ecr", "describe-images"]:
                return json.dumps({"imageDetails": [{"imageDigest": "sha256:test"}]})
            if args[0] == "bash":
                raise RuntimeError("Migracion rechazada por precondicion de datos")
            return ""

        def plan(directory, service, migrate, apply, target=False):
            plans.append((service, apply, target))

        with tempfile.TemporaryDirectory() as root, \
                mock.patch.dict(MAIN.__globals__, command=command, tf=lambda *a: "", plan_and_apply=plan, ROOT=pathlib.Path(root)), \
                mock.patch("runpy.run_path", return_value={"actualizar": mock.Mock()}), \
                mock.patch("sys.argv", ["deploy-release.py", "--service", "api", "--tag", "app-sha", "--migrate-tag", "schema-sha"] + (["--apply"] if apply else [])):
            if apply:
                with self.assertRaisesRegex(RuntimeError, "Migracion rechazada"):
                    MAIN()
            else:
                MAIN()
        return plans, commands

    def test_migration_failure_stops_before_api_apply(self):
        plans, commands = self.run_release(True)
        self.assertEqual(plans, [("api", False, False), ("migrate", True, True)])
        self.assertFalse(any("services-stable" in args for args in commands))

    def test_preview_never_runs_migrations_or_applies_a_plan(self):
        plans, commands = self.run_release(False)
        self.assertEqual(plans, [("api", False, False)])
        self.assertFalse(any(args[0] == "bash" for args in commands))
