import pathlib
import runpy
import tempfile
import unittest

ACTUALIZAR = runpy.run_path(str(pathlib.Path(__file__).parents[1] / "scripts/bump-image-tag.py"))["actualizar"]


class BumpImageTagTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.archivo = pathlib.Path(self.tmp.name) / "images.tfvars"
        self.original = 'image_tags = {\n  "api" = "1.0.0-old"\n}\n'
        self.archivo.write_text(self.original)

    def test_first_cie10_publication_adds_entry_and_preserves_api(self):
        ACTUALIZAR(self.archivo, "cie10", "1.0.0-5cedb4f")
        self.assertIn('"api" = "1.0.0-old"', self.archivo.read_text())
        self.assertIn('"cie10" = "1.0.0-5cedb4f"', self.archivo.read_text())
        ACTUALIZAR(self.archivo, "cie10", "1.0.0-next")
        self.assertEqual(self.archivo.read_text().count('"cie10"'), 1)
        self.assertIn('"cie10" = "1.0.0-next"', self.archivo.read_text())

    def test_invalid_inputs_do_not_modify_manifest(self):
        for servicio, tag in [("unknown", "v1"), ("api", 'bad"\nmalicious = true')]:
            with self.assertRaises(ValueError):
                ACTUALIZAR(self.archivo, servicio, tag)
            self.assertEqual(self.archivo.read_text(), self.original)

    def test_duplicate_entry_is_rejected(self):
        self.archivo.write_text('image_tags = {\n "api" = "v1"\n "api" = "v2"\n}\n')
        with self.assertRaises(ValueError):
            ACTUALIZAR(self.archivo, "api", "v3")
