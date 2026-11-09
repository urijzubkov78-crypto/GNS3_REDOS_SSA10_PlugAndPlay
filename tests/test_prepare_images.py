"""Small real-file regressions for atomic assembly of bundled images."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepare_images", ROOT / "scripts/prepare_images.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrepareImagesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="gns3-parts-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.image = self.root / "test-switch.qcow2"
        self.payload = b"QCOW2 test payload\x00\xffsecond part"
        self.image.with_suffix(".md5").write_text(hashlib.md5(self.payload).hexdigest(), encoding="ascii")
        self.parts = [Path(str(self.image) + suffix) for suffix in (".part01", ".part02")]
        self.parts[0].write_bytes(self.payload[:12])
        self.parts[1].write_bytes(self.payload[12:])

    def assert_no_temporary_image(self):
        self.assertEqual(list(self.root.glob("*.assembling")), [])

    def test_reassembles_exact_bytes_and_repeat_keeps_verified_image(self):
        module.prepare_images(self.root)
        self.assertEqual(self.image.read_bytes(), self.payload)
        before = self.image.stat().st_mtime_ns
        module.prepare_images(self.root)
        self.assertEqual(self.image.stat().st_mtime_ns, before)
        self.assert_no_temporary_image()

    def test_corrupt_part_is_rejected_without_partial_destination(self):
        self.parts[1].write_bytes(b"damaged")
        with self.assertRaisesRegex(ValueError, "MD5"):
            module.prepare_images(self.root)
        self.assertFalse(self.image.exists())
        self.assert_no_temporary_image()

    def test_missing_last_part_is_rejected(self):
        self.parts[1].unlink()
        with self.assertRaisesRegex(ValueError, "MD5"):
            module.prepare_images(self.root)
        self.assertFalse(self.image.exists())
        self.assert_no_temporary_image()

    def test_gap_in_numbering_is_rejected(self):
        self.parts[1].rename(Path(str(self.image) + ".part03"))
        with self.assertRaisesRegex(ValueError, "без пропусков"):
            module.prepare_images(self.root)
        self.assertFalse(self.image.exists())

    def test_failed_rebuild_preserves_existing_image(self):
        self.image.write_bytes(b"previous image")
        self.parts[1].write_bytes(b"damaged")
        with self.assertRaises(ValueError):
            module.prepare_images(self.root)
        self.assertEqual(self.image.read_bytes(), b"previous image")
        self.assert_no_temporary_image()

    def test_valid_existing_image_does_not_need_parts(self):
        self.image.write_bytes(self.payload)
        self.parts[1].unlink()
        self.assertFalse(module.prepare_image(self.image, self.parts[:1]))
        self.assertEqual(self.image.read_bytes(), self.payload)

    def test_checksum_file_is_required(self):
        self.image.with_suffix(".md5").unlink()
        with self.assertRaisesRegex(ValueError, "Нет соседнего"):
            module.prepare_images(self.root)
        self.assertFalse(self.image.exists())


if __name__ == "__main__":
    unittest.main()
