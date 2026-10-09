import unittest
from unittest.mock import patch
import tempfile
from pathlib import Path

import webcam_settings as ws


class PresetTests(unittest.TestCase):
    def setUp(self):
        self.cameras = [
            {"id": "32e4:0317", "name": "HD USB CAMERA", "serial": "01.00.00",
             "location": "00110000"},
            {"id": "32e4:0317", "name": "HD USB CAMERA", "serial": "01.00.00",
             "location": "00130000"},
        ]

    def test_identical_cameras_are_selected_by_port(self):
        preset = {"label": "Desk", "id": "32e4:0317", "serial": "01.00.00",
                  "location": "00130000", "match": "port"}
        self.assertEqual(ws.resolve(preset, self.cameras), self.cameras[1])
        with self.assertRaises(RuntimeError):
            ws.resolve(preset, self.cameras[:1])

    def test_preview_capture_id_matches_usb_location(self):
        self.assertEqual(ws.capture_id(self.cameras[0]), "0x11000032e40317")
        self.assertEqual(ws.capture_id(self.cameras[1]), "0x13000032e40317")

    def test_auto_modes_are_restored_after_manual_controls(self):
        preset = {"label": "Desk", "id": "32e4:0317", "serial": "01.00.00",
                  "location": "00130000", "match": "port",
                  "values": {"exposure_auto": 1, "exposure_time_absolute": 250,
                             "white_balance_temperature_auto": 0,
                             "white_balance_temperature": 5000}}
        calls = []
        control_state = {"exposure_auto": 8, "exposure_time_absolute": 100,
                         "white_balance_temperature_auto": 1,
                         "white_balance_temperature": 4600}

        def fake_caps(_):
            return {"controls": [{"name": k, "value": v, "writable": True}
                                  for k, v in control_state.items()]}

        def fake_write(_, name, value):
            calls.append((name, value))
            control_state[name] = value
            return value

        with patch.object(ws, "caps", fake_caps), patch.object(ws, "write_control", fake_write):
            result = ws.apply_preset(preset, self.cameras)
        self.assertTrue(result["ok"], result["errors"])
        self.assertLess(calls.index(("exposure_auto", 1)),
                        calls.index(("exposure_time_absolute", 250)))
        self.assertLess(calls.index(("white_balance_temperature_auto", 0)),
                        calls.index(("white_balance_temperature", 5000)))

    def test_sync_copies_exact_values_and_preserves_target_identity(self):
        source = {"label": "Key", "id": "32e4:0317", "name": "HD USB CAMERA",
                  "serial": "01.00.00", "location": "00110000", "match": "port",
                  "values": {"gain": 42, "exposure_auto": 1}}
        target = {**source, "label": "Fill", "location": "00130000",
                  "values": {"gain": 7, "exposure_auto": 2}}
        controls = [{"name": name, "value": value, "writable": True,
                     "min": 0, "max": 100} for name, value in source["values"].items()]
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(ws, "STATE", Path(directory) / "presets.json"), \
             patch.object(ws, "cameras", return_value=self.cameras), \
             patch.object(ws, "caps", return_value={"controls": controls}), \
             patch.object(ws, "apply_preset", return_value={"label": "Fill",
                                                            "location": "00130000",
                                                            "ok": True, "errors": []}):
            ws.save_state({"version": 1, "presets": [source, target]})
            results = ws.sync_preset("00110000", ["00130000"])
            saved = ws.read_state()["presets"]
        self.assertTrue(results[0]["ok"])
        copied = next(p for p in saved if p["location"] == "00130000")
        self.assertEqual(copied["values"], source["values"])
        self.assertEqual(copied["label"], "Fill")
        self.assertEqual(copied["match"], "port")

    def test_sync_rejects_incompatible_target_before_writing(self):
        source = {"label": "Key", "id": "32e4:0317", "name": "HD USB CAMERA",
                  "serial": "01.00.00", "location": "00110000", "match": "port",
                  "values": {"gain": 42}}
        with patch.object(ws, "cameras", return_value=self.cameras), \
             patch.object(ws, "read_state", return_value={"version": 1, "presets": [source]}), \
             patch.object(ws, "caps", return_value={"controls": []}), \
             patch.object(ws, "apply_preset") as apply:
            with self.assertRaisesRegex(ValueError, "gain is unavailable"):
                ws.sync_preset("00110000", ["00130000"])
            apply.assert_not_called()

    def test_failed_sync_keeps_existing_target_profile(self):
        source = {"label": "Key", "id": "32e4:0317", "name": "HD USB CAMERA",
                  "serial": "01.00.00", "location": "00110000", "match": "port",
                  "values": {"gain": 42}}
        target = {**source, "label": "Fill", "location": "00130000",
                  "values": {"gain": 7}}
        controls = [{"name": "gain", "value": 7, "writable": True,
                     "min": 0, "max": 100}]
        failure = {"label": "Fill", "location": "00130000", "ok": False,
                   "errors": ["gain: final readback 7, expected 42"]}
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(ws, "STATE", Path(directory) / "presets.json"), \
             patch.object(ws, "cameras", return_value=self.cameras), \
             patch.object(ws, "caps", return_value={"controls": controls}), \
             patch.object(ws, "apply_preset", return_value=failure):
            ws.save_state({"version": 1, "presets": [source, target]})
            result = ws.sync_preset("00110000", ["00130000"])
            saved = ws.read_state()["presets"]
        self.assertEqual(result, [failure])
        self.assertEqual(saved[1], target)


if __name__ == "__main__":
    unittest.main()
