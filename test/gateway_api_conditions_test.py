"""Stale or partial controller status must not pass the bootstrap gate."""
import importlib.util
import pathlib
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / "scripts/lib/check-gateway-api.py"
spec = importlib.util.spec_from_file_location("gateway_check", path)
gateway_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway_check)


class ConditionsTest(unittest.TestCase):
    def test_only_current_true_condition_passes(self):
        self.assertTrue(gateway_check.current_condition([
            {"type": "Programmed", "status": "True", "observedGeneration": 7},
        ], "Programmed", 7))
        for condition in (
            {"type": "Programmed", "status": "True", "observedGeneration": 6},
            {"type": "Programmed", "status": "False", "observedGeneration": 7},
            {"type": "Programmed", "status": "Unknown", "observedGeneration": 7},
            {"type": "Programmed", "status": "True"},
            {"type": "Accepted", "status": "True", "observedGeneration": 7},
        ):
            with self.subTest(condition=condition):
                self.assertFalse(gateway_check.current_condition([condition], "Programmed", 7))
        self.assertFalse(gateway_check.current_condition([], "Programmed", 7))


if __name__ == "__main__":
    unittest.main()
