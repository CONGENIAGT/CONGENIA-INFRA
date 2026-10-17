import copy
from contextlib import redirect_stdout
import io
import json
import pathlib
import runpy
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace

MODULE = runpy.run_path(str(pathlib.Path(__file__).parents[1] / "scripts/deploy-release.py"))
GUARD = MODULE["guard_plan"]
MAIN = MODULE["main"]


def request(**overrides):
    values = dict(service="selected", components="frontend,pdf-worker", latest=True, tag="", migrate_tag="", resolved_tags="")
    return SimpleNamespace(**(values | overrides))


class SelectionTests(unittest.TestCase):
    def test_multiple_components_and_all_exclude_migrations(self):
        self.assertEqual(MODULE["selected_services"](request()), {"frontend", "pdf-worker"})
        self.assertEqual(MODULE["selected_services"](request(components="all")), MODULE["COMPONENTS"])
        self.assertNotIn("migrate", MODULE["selected_services"](request(components="all")))

    def test_invalid_or_ambiguous_combinations_fail_before_aws(self):
        cases = [dict(components=""), dict(components="frontend,"), dict(components="frontend,frontend"),
                 dict(components="frontend,migrate"), dict(components="rabbitmq"), dict(components="all,api"),
                 dict(tag="1.0.0-abcdef0"), dict(migrate_tag="schema-abcdef0"),
                 dict(service="manifest", components="", latest=True),
                 dict(service="migrate", components="", latest=True),
                 dict(service="frontend", components="frontend"),
                 dict(resolved_tags='{"frontend":"v1"}'),
                 dict(service="manifest", components="", latest=False, resolved_tags='{}')]
        for overrides in cases:
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                MODULE["selected_services"](request(**overrides))

    def test_api_migration_is_explicit_and_single_tag_remains_supported(self):
        self.assertEqual(MODULE["selected_services"](request(components="api,frontend", migrate_tag="schema-abcdef0")), {"api", "frontend"})
        self.assertEqual(MODULE["selected_services"](request(service="frontend", components="", latest=False, tag="1.0.0-abcdef0")), {"frontend"})
        with self.assertRaises(ValueError):
            MODULE["selected_services"](request(service="frontend", components="", latest=False))


class LatestImageTests(unittest.TestCase):
    def latest(self, images):
        function = MODULE["latest_image"]
        with mock.patch.dict(function.__globals__, ecr_images=lambda service: images):
            return function("frontend")

    def test_latest_uses_push_time_not_tag_order_and_ignores_aliases_and_untagged(self):
        images = [
            {"imagePushedAt": 50, "imageTags": ["9.0.0-aaaaaaa"], "imageDigest": "old"},
            {"imagePushedAt": 70, "imageTags": ["latest", "1.0.0-bbbbbbb"], "imageDigest": "new"},
            {"imagePushedAt": 100, "imageTags": ["dev", "latest"]},
            {"imagePushedAt": 110},
        ]
        tag, image = self.latest(images)
        self.assertEqual((tag, image["imageDigest"]), ("1.0.0-bbbbbbb", "new"))

    def test_timezone_offsets_are_compared_as_instants(self):
        images = [
            {"imagePushedAt": "2026-10-17T01:00:00Z", "imageTags": ["1.0.0-aaaaaaa"]},
            {"imagePushedAt": "2026-10-16T21:00:00-06:00", "imageTags": ["1.0.0-bbbbbbb"]},
        ]
        self.assertEqual(self.latest(images)[0], "1.0.0-bbbbbbb")

    def test_no_valid_tag_or_ambiguous_latest_fails_without_fallback(self):
        for images in [[], [{"imagePushedAt": 1, "imageTags": ["latest"]}],
                       [{"imagePushedAt": 1, "imageTags": ["1.0.0-aaaaaaa", "1.0.0-bbbbbbb"]}],
                       [{"imagePushedAt": 1, "imageTags": [tag]} for tag in ["1.0.0-aaaaaaa", "1.0.0-bbbbbbb"]]]:
            with self.subTest(images=images), self.assertRaises(ValueError): self.latest(images)

    def test_ecr_query_is_tagged_and_not_truncated_before_sorting(self):
        command = mock.Mock(return_value='{"imageDetails": []}')
        with mock.patch.dict(MODULE["ecr_images"].__globals__, command=command):
            MODULE["ecr_images"]("frontend")
        args = command.call_args.args[0]
        self.assertIn("tagStatus=TAGGED", args)
        for flag in ["--max-items", "--no-paginate", "--query"]: self.assertNotIn(flag, args)


class ResolvedImagesTests(unittest.TestCase):
    def test_pinned_preview_tags_use_exact_lookup_even_if_a_new_release_exists(self):
        args = request(latest=False, resolved_tags='{"frontend":"1.0.0-aaaaaaa","pdf-worker":"1.0.0-bbbbbbb"}')
        lookup = mock.Mock(side_effect=lambda service, tag: [{"imageTags": [tag], "imageDigest": "sha256:test"}])
        latest = mock.Mock(side_effect=AssertionError("No resolver latest para versiones fijadas"))
        function = MODULE["resolved_images"]
        with mock.patch.dict(function.__globals__, ecr_images=lookup, latest_image=latest), redirect_stdout(io.StringIO()):
            images = function(args, MODULE["selected_services"](args))
        self.assertEqual(images, json.loads(args.resolved_tags))
        self.assertEqual(lookup.call_args_list, [mock.call("frontend", "1.0.0-aaaaaaa"), mock.call("pdf-worker", "1.0.0-bbbbbbb")])

    def test_pinned_json_requires_exact_services_unique_keys_and_valid_tags(self):
        for text in ['[]', '{"frontend":"v1"}', '{"frontend":"v1","migrate":"schema-abc"}',
                     '{"frontend":"v1","frontend":"v2","pdf-worker":"v3"}',
                     '{"frontend":null,"pdf-worker":"v1"}', '{"frontend":"bad tag","pdf-worker":"v1"}', '{broken']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                MODULE["resolved_images"](request(latest=False, resolved_tags=text), {"frontend", "pdf-worker"})

    def test_selected_without_latest_uses_only_its_manifest_subset(self):
        function = MODULE["resolved_images"]
        lookup = lambda service, tag: [{"imageTags": [tag], "imageDigest": "sha256:test"}]
        with mock.patch.dict(function.__globals__, ecr_images=lookup), redirect_stdout(io.StringIO()):
            images = function(request(latest=False), {"frontend", "pdf-worker"})
        manifest = MODULE["manifest_images"](MODULE["ROOT"] / "envs/aws/images.tfvars")
        self.assertEqual(images, {name: manifest[name] for name in ["frontend", "pdf-worker"]})

    def test_latest_api_uses_explicit_migration_tag_never_latest_sql(self):
        function = MODULE["resolved_images"]
        latest = mock.Mock(return_value=("1.0.0-aaaaaaa", {"imageDigest": "sha256:app"}))
        lookup = mock.Mock(return_value=[{"imageTags": ["schema-bbbbbbb"], "imageDigest": "sha256:sql"}])
        with mock.patch.dict(function.__globals__, latest_image=latest, ecr_images=lookup), redirect_stdout(io.StringIO()):
            images = function(request(components="api", migrate_tag="schema-bbbbbbb"), {"api"})
        self.assertEqual(images, {"api": "1.0.0-aaaaaaa", "migrate": "schema-bbbbbbb"})
        latest.assert_called_once_with("api")
        lookup.assert_called_once_with("migrate", "schema-bbbbbbb")


class CurrentImagesTests(unittest.TestCase):
    def test_compare_against_service_and_scheduler_targets_not_manifest_or_latest_family(self):
        commands = []
        definitions = {"frontend": "frontend:27", "pdf-worker": "pdf-worker:12", "cie10": "cie10:4", "migrate": "migrate:8"}
        def command(args):
            commands.append(args)
            if args[1:3] == ["ecs", "describe-services"]:
                return json.dumps({"services": [{"serviceName": "congenia-prod-" + name, "taskDefinition": definitions[name]} for name in ["frontend", "pdf-worker"]]})
            if args[1:3] == ["scheduler", "get-schedule"]: return json.dumps(definitions["cie10"])
            definition = args[args.index("--task-definition") + 1]
            service = definition.split(":")[0]
            return json.dumps([{"name": service, "image": "940213460779.dkr.ecr.us-east-1.amazonaws.com/congenia/" + service + ":1.0.0-aaaaaaa"}])
        outputs = {"region": "us-east-1", "ecs_cluster": "congenia-prod-cluster", "migrate_task_definition": definitions["migrate"]}
        function = MODULE["current_images"]
        with mock.patch.dict(function.__globals__, command=command, output=outputs.__getitem__):
            images = function(set(definitions))
        self.assertEqual(images, dict.fromkeys(definitions, "1.0.0-aaaaaaa"))
        queried = {args[args.index("--task-definition") + 1] for args in commands if "--task-definition" in args}
        self.assertEqual(queried, set(definitions.values()))

    def test_missing_ecs_service_stops_comparison(self):
        function = MODULE["current_images"]
        with mock.patch.dict(function.__globals__, command=lambda args: '{"services":[],"failures":[{}]}', output=lambda name: "congenia-prod-cluster"), self.assertRaises(ValueError):
            function({"frontend"})

    def test_summary_distinguishes_unchanged_images_and_excludes_sql_from_pinned_components(self):
        function = MODULE["release_summary"]
        with tempfile.TemporaryDirectory() as directory:
            summary = pathlib.Path(directory, "summary.md")
            with mock.patch.dict("os.environ", GITHUB_STEP_SUMMARY=str(summary)), redirect_stdout(io.StringIO()):
                function({"frontend": "1.0.0-aaaaaaa", "migrate": "schema-bbbbbbb"}, {"frontend": "1.0.0-aaaaaaa", "migrate": "schema-old"})
            content = summary.read_text()
        self.assertIn("sin cambio", content)
        pinned = json.loads(content.split("```json\n")[1].split("\n```")[0])
        self.assertEqual(pinned, {"frontend": "1.0.0-aaaaaaa"})
        self.assertIn("no confirma que el SQL", content)


class FailureDiagnosticsTests(unittest.TestCase):
    def test_denied_operations_are_reported_without_values_or_plan_payload(self):
        secret = "test-private-value-that-must-not-appear"
        stderr = (
            'Error: reading Secret: operation error Secrets Manager: GetResourcePolicy, '
            'api error AccessDeniedException: User is not authorized to perform: secretsmanager:GetResourcePolicy on resource: "private-arn"\n'
            'Error: reading S3: operation error S3: GetBucketReplication, '
            'User is not authorized to perform: s3:GetReplicationConfiguration\n'
        )
        result = subprocess_result = mock.Mock(returncode=1, stdout=secret, stderr=stderr)
        with mock.patch("subprocess.run", return_value=subprocess_result):
            with self.assertRaises(RuntimeError) as error:
                MODULE["command"](["terraform", "-chdir=envs/aws", "plan"])
        message = str(error.exception)
        self.assertIn("terraform plan", message)
        self.assertIn("secretsmanager:GetResourcePolicy", message)
        self.assertIn("s3:GetReplicationConfiguration", message)
        self.assertNotIn(secret, message)
        self.assertNotIn("private-arn", message)

    def test_unrecognized_errors_never_dump_response_or_credentials(self):
        result = MODULE["failure_diagnostics"]('password = "private-value"', 'Error: arbitrary-provider-secret-private-value')
        self.assertNotIn("private-value", result)
        self.assertIn("No hay metadatos reconocidos", result)

    def test_lock_failure_and_known_core_errors_are_actionable(self):
        self.assertIn("bloqueo", MODULE["failure_diagnostics"]('', 'Error: Error acquiring the state lock'))
        self.assertIn("Unsupported argument", MODULE["failure_diagnostics"]('', 'Error: Unsupported argument\nsecret = "private-value"'))


class ManifestTests(unittest.TestCase):
    def test_six_literal_tags_including_cie10_and_reject_missing_or_duplicate(self):
        services = ["api", "frontend", "pdf-worker", "keycloak", "cie10", "migrate"]
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory, "images.tfvars")
            for names in [services, services[:-1], services + ["api"]]:
                path.write_text('image_tags = {\n' + ''.join(f'  "{name}" = "v1-{name}"\n' for name in names) + '}\n')
                if names == services:
                    self.assertEqual(MODULE["manifest_images"](path)["cie10"], "v1-cie10")
                else:
                    with self.assertRaises(ValueError): MODULE["manifest_images"](path)


def task(module="api"):
    before = {"family": "congenia-prod-" + module, "container_definitions": json.dumps([{"name": module, "image": "ecr/old", "environment": [{"name": "X", "value": "existing"}]}])}
    after = copy.deepcopy(before)
    after["container_definitions"] = after["container_definitions"].replace("ecr/old", "ecr/new")
    return {"mode": "managed", "type": "aws_ecs_task_definition", "address": f"module.{module}.aws_ecs_task_definition.this", "change": {"actions": ["delete", "create"], "before": before, "after": after}}


class ReleaseGuardTests(unittest.TestCase):
    def test_selected_union_stays_scoped_and_migration_requires_explicit_inclusion(self):
        plan = {"resource_changes": [task("frontend"), task("pdf_worker")]}
        self.assertEqual(len(GUARD(plan, {"frontend", "pdf-worker"})), 2)
        plan["resource_changes"].append(task("api"))
        with self.assertRaises(ValueError): GUARD(plan, {"frontend", "pdf-worker"})
        plan["resource_changes"][-1] = task("migrate")
        with self.assertRaises(ValueError): GUARD(plan, {"frontend", "pdf-worker"})
        self.assertEqual(len(GUARD(plan, {"frontend", "pdf-worker"}, True)), 3)

    def test_image_replacement_is_allowed_without_treating_it_as_data_destruction(self):
        self.assertEqual(len(GUARD({"resource_changes": [task()]}, "api")), 1)

    def test_api_and_optional_migration_can_be_planned_together(self):
        plan = {"resource_changes": [task(), task("migrate")]}
        self.assertEqual(len(GUARD(plan, "api", True)), 2)
        with self.assertRaises(ValueError): GUARD(plan, "api")

    def test_manifest_allows_multiple_images_but_never_data_changes(self):
        plan = {"resource_changes": [task(), task("frontend")]}
        self.assertEqual(len(GUARD(plan, "manifest")), 2)
        extra = task()
        extra["address"] = "module.data.aws_db_instance.postgres"
        plan["resource_changes"].append(extra)
        with self.assertRaises(ValueError): GUARD(plan, "manifest", runtime_config=True)

    def test_runtime_variables_require_explicit_option_and_roles_remain_protected(self):
        resource = task()
        resource["change"]["after"]["container_definitions"] = resource["change"]["after"]["container_definitions"].replace("existing", "changed")
        with self.assertRaises(ValueError): GUARD({"resource_changes": [resource]}, "api")
        self.assertEqual(len(GUARD({"resource_changes": [resource]}, "api", runtime_config=True)), 1)
        resource["change"]["after"]["task_role_arn"] = "other-role"
        with self.assertRaises(ValueError): GUARD({"resource_changes": [resource]}, "api", runtime_config=True)

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
                tag = next(arg.removeprefix("imageTag=") for arg in args if arg.startswith("imageTag="))
                return json.dumps({"imageDetails": [{"imageDigest": "sha256:test", "imageTags": [tag]}]})
            if args[0] == "bash":
                raise RuntimeError("Migracion rechazada por precondicion de datos")
            return ""

        def plan(directory, service, migrate, apply, target=False, runtime_config=False):
            plans.append((service, apply, target))

        with tempfile.TemporaryDirectory() as root, \
                mock.patch.dict(MAIN.__globals__, command=command, tf=lambda *a: "", plan_and_apply=plan, ROOT=pathlib.Path(root), current_images=lambda services: {name: "old-tag" for name in services}, release_summary=mock.Mock()), \
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


class MultipleReleaseTests(unittest.TestCase):
    def run_release(self, components, apply=False, migrate_tag="", fail_migration=False, fail_resolution=False):
        events = []
        selected = set(components.split(",")) if components != "all" else MODULE["COMPONENTS"]
        def latest(service):
            events.append(("resolve", service))
            if fail_resolution and service == "pdf-worker": raise ValueError("No hay imagen")
            return "1.0.0-aaaaaaa", {"imageDigest": "sha256:test"}
        def command(args, capture=True):
            events.append(("command", args))
            if args[0] == "bash" and fail_migration: raise RuntimeError("SQL fallo")
            if args[1:3] == ["ecs", "describe-services"]:
                return json.dumps({"services": [{"serviceName": "congenia-prod-" + service, "taskDefinition": service + ":1", "deployments": [{}], "runningCount": 1, "desiredCount": 1} for service in selected - {"cie10"}]})
            return ""
        def plan(directory, service, migrate, apply, target=False, runtime_config=False):
            events.append(("plan", service, migrate, apply, target))
        def tf(*args):
            if args[:2] == ("output", "-json"): return json.dumps({service: service + ":1" for service in selected})
            return ""
        def update(*args): events.append(("manifest", args[1]))
        argv = ["deploy-release.py", "--service", "selected", "--components", components, "--latest"]
        if apply: argv.append("--apply")
        if migrate_tag: argv += ["--migrate-tag", migrate_tag]
        patches = dict(command=command, tf=tf, plan_and_apply=plan, latest_image=latest,
                       release_summary=mock.Mock(),
                       output=lambda name: "us-east-1" if name == "region" else "congenia-prod-cluster",
                       current_images=lambda services: dict.fromkeys(services, "old"),
                       ecr_images=lambda service, tag: [{"imageTags": [tag], "imageDigest": "sha256:sql"}])
        with mock.patch.dict(MAIN.__globals__, **patches), mock.patch("runpy.run_path", return_value={"actualizar": update}), mock.patch("sys.argv", argv), redirect_stdout(io.StringIO()):
            if fail_migration:
                with self.assertRaisesRegex(RuntimeError, "SQL fallo"): MAIN()
            elif fail_resolution:
                with redirect_stdout(io.StringIO()), mock.patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit): MAIN()
            else: MAIN()
        return events

    def test_multiple_latest_applies_only_selected_services_and_checks_both_revisions(self):
        events = self.run_release("frontend,pdf-worker", apply=True)
        plans = [event for event in events if event[0] == "plan"]
        self.assertEqual(plans, [("plan", {"frontend", "pdf-worker"}, False, False, False), ("plan", {"frontend", "pdf-worker"}, False, True, False)])
        commands = [event[1] for event in events if event[0] == "command"]
        self.assertFalse(any(args[0] == "bash" for args in commands))
        waiter = next(args for args in commands if "services-stable" in args)
        self.assertEqual(waiter[waiter.index("--services") + 1:], ["congenia-prod-frontend", "congenia-prod-pdf-worker"])
        self.assertEqual(commands[-1], ["make", "smoke", "ENV=aws"])

    def test_all_latest_preview_never_resolves_migrations_or_applies(self):
        events = self.run_release("all")
        self.assertEqual({event[1] for event in events if event[0] == "resolve"}, MODULE["COMPONENTS"])
        self.assertFalse(any(event[0] == "command" for event in events))
        self.assertEqual([event for event in events if event[0] == "plan"], [("plan", MODULE["COMPONENTS"], False, False, False)])

    def test_one_missing_image_stops_before_manifest_updates_or_planning(self):
        events = self.run_release("frontend,pdf-worker", fail_resolution=True)
        self.assertFalse(any(event[0] in {"manifest", "plan", "command"} for event in events))

    def test_explicit_sql_failure_stops_all_selected_component_applies(self):
        events = self.run_release("api,frontend", apply=True, migrate_tag="schema-bbbbbbb", fail_migration=True)
        self.assertEqual([event for event in events if event[0] == "plan"], [("plan", {"api", "frontend"}, True, False, False), ("plan", "migrate", False, True, True)])
