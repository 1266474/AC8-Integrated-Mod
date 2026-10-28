import csv
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("analyze_frames", Path(__file__).resolve().parents[1] / "tools/analyze_frames.py")
a = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(a)


class FrameTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.csv = Path(self.temp.name) / "frames.csv"

    def write(self, rows, names=None):
        with self.csv.open("w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(names or ["Application", "SwapChainAddress", "TimeInSeconds", "MsBetweenPresents"])
            writer.writerows(rows)

    def test_real_metrics_and_phase_boundaries(self):
        rows = [["AceCombat8.exe", "0x1", 100 + i / 10, 10 if i < 100 or i >= 300 else 20] for i in range(400)]
        rows[150][-1] = 60
        rows[250][-1] = 120
        self.write(rows)
        result = a.analyze(self.csv)
        self.assertTrue(result["usable_for_acceptance"])
        self.assertEqual(result["total"]["frames"], 400)
        self.assertEqual(result["phases"]["steady_drag"]["frames"], 100)
        self.assertEqual(result["phases"]["reverse_drag"]["over_100ms"], 1)
        self.assertEqual(result["drag_combined"]["over_50ms"], 2)
        self.assertEqual(result["drag_combined"]["p50_ms"], 20)

    def test_auxiliary_swapchain_and_other_process_excluded(self):
        self.write([["AceCombat8.exe", "main", i / 10, 16] for i in range(400)] +
                   [["AceCombat8.exe", "overlay", i / 10, 1] for i in range(10)] +
                   [["Other.exe", "other", 0, 1000]])
        result = a.analyze(self.csv)
        self.assertEqual(result["selected_swapchain"], "main")
        self.assertEqual(result["ignored_other_swapchains"], 10)
        self.assertEqual(result["ignored_other_process"], 1)
        self.assertEqual(result["total"]["p99_ms"], 16)

    def test_short_capture_is_not_pass(self):
        self.write([["AceCombat8.exe", "main", i, 16] for i in range(5)])
        result = a.analyze(self.csv)
        self.assertFalse(result["complete_40s"])
        self.assertFalse(a.compare(result, result)["p99_target_met"])

    def test_two_substantial_swapchains_require_explicit_selection(self):
        self.write([["AceCombat8.exe", "main", i / 10, 16] for i in range(400)] +
                   [["AceCombat8.exe", "aux", i / 10, 1] for i in range(400)])
        result = a.analyze(self.csv)
        self.assertTrue(result["swapchain_ambiguous"])
        self.assertFalse(result["usable_for_acceptance"])
        result = a.analyze(self.csv, swapchain="main")
        self.assertTrue(result["usable_for_acceptance"])
        with self.assertRaisesRegex(ValueError, "absent"):
            a.analyze(self.csv, swapchain="missing")

    def test_official_presentmon_26_v1_header_fixture(self):
        # Actual official --v1_metrics header, with synthetic anonymous rows.
        header = "Application,ProcessID,SwapChainAddress,Runtime,SyncInterval,PresentFlags,Dropped,TimeInSeconds,msInPresentAPI,msBetweenPresents,AllowsTearing,PresentMode,msUntilRenderComplete,msUntilDisplayed,msBetweenDisplayChange,msFlipDelay,msUntilRenderStart,msGPUActive,msSinceInput".split(",")
        rows = [["AceCombat8.exe", 0, "0x1", "DXGI", 1, 0, 0, i / 10, .2, 16, 0,
                 "Composed: Flip", 3, 10, 16, 0, 0, 5, 0] for i in range(400)]
        self.write(rows, header)
        result = a.analyze(self.csv)
        self.assertTrue(result["usable_for_acceptance"])
        self.assertEqual(result["total"]["frames"], 400)
        self.assertEqual(result["total"]["p99_ms"], 16)
        self.assertEqual(result["selected_swapchain"], "0x1")

    def test_case_ambiguous_duplicate_headers_are_refused(self):
        self.write([[0, 16, 32]], ["TimeInSeconds", "MsBetweenPresents", "msBetweenPresents"])
        with self.assertRaisesRegex(ValueError, "duplicate column"):
            a.analyze(self.csv)

    def test_invalid_rows_make_acceptance_unusable(self):
        self.write([["AceCombat8.exe", "main", i / 10, 16] for i in range(400)] +
                   [["AceCombat8.exe", "main", 40, "NaN"]])
        result = a.analyze(self.csv)
        self.assertEqual(result["invalid_rows"], 1)
        self.assertFalse(result["usable_for_acceptance"])

    def test_missing_or_empty_data_rejected(self):
        self.write([], ["not", "PresentMon"])
        with self.assertRaisesRegex(ValueError, "must contain"):
            a.analyze(self.csv)
        self.write([])
        with self.assertRaisesRegex(ValueError, "no presentations"):
            a.analyze(self.csv)

    def test_nonmonotonic_capture_refused(self):
        self.write([["AceCombat8.exe", "main", 10, 16], ["AceCombat8.exe", "main", 9, 16]])
        with self.assertRaisesRegex(ValueError, "backwards"):
            a.analyze(self.csv)

    def test_p99_comparison_does_not_imply_visual_acceptance(self):
        self.write([["AceCombat8.exe", "main", i / 10, 40] for i in range(400)])
        before = a.analyze(self.csv)
        self.write([["AceCombat8.exe", "main", i / 10, 20] for i in range(400)])
        after = a.analyze(self.csv)
        result = a.compare(before, after)
        self.assertEqual(result["drag_p99_reduction_percent"], 50)
        self.assertTrue(result["p99_target_met"])
        self.assertIn("three repeated runs", result["note"])


if __name__ == "__main__":
    unittest.main()
