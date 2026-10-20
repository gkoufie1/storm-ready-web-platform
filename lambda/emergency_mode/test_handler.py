"""Unit tests for the Emergency Mode Lambda. Run: python -m unittest -v"""

import json
import os
import unittest
from unittest import mock

os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ["CONFIG"] = json.dumps({
    "parameter_name": "/test/emergency-mode",
    "ecs": {
        "resource_id": "service/c/s",
        "on": {"min": 4, "max": 20},
        "off": {"min": 1, "max": 4},
    },
    "aurora": {
        "cluster_id": "test-aurora",
        "on": {"min": 2, "max": 16, "auto_pause_seconds": 900},
        "off": {"min": 0, "max": 4, "auto_pause_seconds": 900},
    },
    "cloudfront": {
        "cache_policy_id": "cp-123",
        "on": {"min": 300, "default": 600, "max": 86400},
        "off": {"min": 0, "default": 60, "max": 86400},
    },
})

import handler  # noqa: E402


def sns_event(state, alarm="surge"):
    message = json.dumps({"NewStateValue": state, "AlarmName": alarm})
    return {"Records": [{"Sns": {"Message": message}}]}


class EmergencyModeTest(unittest.TestCase):
    def setUp(self):
        self.clients = {}
        for name in ("autoscaling", "rds", "cloudfront", "ssm"):
            patcher = mock.patch.object(handler, name)
            self.clients[name] = patcher.start()
            self.addCleanup(patcher.stop)
        self.clients["cloudfront"].get_cache_policy_config.return_value = {
            "ETag": "E1",
            "CachePolicyConfig": {"Name": "p", "MinTTL": 0, "DefaultTTL": 60, "MaxTTL": 86400},
        }

    def test_on_applies_emergency_profile(self):
        result = handler.handler({"mode": "on", "requested_by": "test"}, None)

        self.clients["autoscaling"].register_scalable_target.assert_called_once_with(
            ServiceNamespace="ecs",
            ResourceId="service/c/s",
            ScalableDimension="ecs:service:DesiredCount",
            MinCapacity=4,
            MaxCapacity=20,
        )
        scaling = self.clients["rds"].modify_db_cluster.call_args.kwargs["ServerlessV2ScalingConfiguration"]
        self.assertEqual(scaling, {"MinCapacity": 2, "MaxCapacity": 16})

        update = self.clients["cloudfront"].update_cache_policy.call_args.kwargs
        self.assertEqual(update["IfMatch"], "E1")
        self.assertEqual(update["CachePolicyConfig"]["MinTTL"], 300)
        self.assertEqual(update["CachePolicyConfig"]["DefaultTTL"], 600)
        self.assertEqual(update["CachePolicyConfig"]["Name"], "p")  # rest of policy preserved

        self.assertEqual(result["mode"], "on")
        self.clients["ssm"].put_parameter.assert_called_once()

    def test_off_restores_auto_pause(self):
        handler.handler({"mode": "off"}, None)
        scaling = self.clients["rds"].modify_db_cluster.call_args.kwargs["ServerlessV2ScalingConfiguration"]
        self.assertEqual(scaling, {"MinCapacity": 0, "MaxCapacity": 4, "SecondsUntilAutoPause": 900})

    def test_alarm_turns_on(self):
        result = handler.handler(sns_event("ALARM"), None)
        self.assertEqual(result["mode"], "on")
        self.assertEqual(result["requested_by"], "alarm:surge")

    def test_alarm_recovery_never_turns_off(self):
        result = handler.handler(sns_event("OK"), None)
        self.assertEqual(result, {"skipped": True})
        self.clients["autoscaling"].register_scalable_target.assert_not_called()

    def test_invalid_mode_rejected(self):
        with self.assertRaises(ValueError):
            handler.handler({"mode": "panic"}, None)

    def test_partial_failure_still_runs_other_steps_and_raises(self):
        self.clients["rds"].modify_db_cluster.side_effect = Exception("throttled")
        with self.assertRaises(RuntimeError):
            handler.handler({"mode": "on"}, None)
        self.clients["autoscaling"].register_scalable_target.assert_called_once()
        self.clients["cloudfront"].update_cache_policy.assert_called_once()
        stored = json.loads(self.clients["ssm"].put_parameter.call_args.kwargs["Value"])
        self.assertTrue(stored["results"]["aurora"].startswith("FAILED"))


if __name__ == "__main__":
    unittest.main()
