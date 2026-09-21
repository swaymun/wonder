import importlib.util
import math
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('generate_ios', Path(__file__).with_name('generate-ios.py'))
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class NativeGeometryTests(unittest.TestCase):
    def test_quarter_arc_keeps_sweep_and_tangent(self):
        curves = generator.arc((1, 0), 1, 1, 0, 0, 1, (0, 1))
        self.assertEqual(len(curves), 2)
        self.assertEqual(curves[-1][-1], (0, 1))
        self.assertEqual(curves[0][1][0], 1)
        self.assertGreater(curves[0][1][1], 0)
        self.assertAlmostEqual(curves[0][-1][0], math.sqrt(0.5))
        self.assertAlmostEqual(curves[0][-1][1], math.sqrt(0.5))

    def test_large_arc_keeps_the_crescent_outer_body(self):
        short = generator.arc((1, 0), 1, 1, 0, 0, 1, (0, 1))
        large = generator.arc((1, 0), 1, 1, 0, 1, 0, (0, 1))
        self.assertEqual(len(large), 6)
        self.assertTrue(all(p[-1][0] >= 0 for p in short))
        self.assertTrue(any(p[-1][0] < 0 for p in large))
        self.assertTrue(any(p[-1][1] < 0 for p in large))
        self.assertEqual(large[-1][-1], (0, 1))

    def test_degenerate_and_out_of_range_radii(self):
        self.assertEqual(generator.arc((0, 0), 0, 1, 0, 0, 1, (10, 0)), [('L', (10, 0))])
        self.assertEqual(generator.arc((0, 0), 1, 1, 0, 0, 1, (0, 0)), [])
        curves = generator.arc((0, 0), 1, 1, 30, 0, 1, (10, 0))
        self.assertEqual(curves[-1][-1], (10, 0))
        self.assertTrue(all(math.isfinite(n) for curve in curves for p in curve[1:] for n in p))

    def test_relative_commands_and_reflected_controls(self):
        commands = generator.path_commands('M10 20c1 2 3 4 5 6s7 8 9 10q1 2 3 4t5 6z')
        self.assertEqual(commands[1], ('C', (11, 22), (13, 24), (15, 26)))
        self.assertEqual(commands[2], ('C', (17, 28), (22, 34), (24, 36)))
        self.assertEqual(commands[3], ('Q', (25, 38), (27, 40)))
        self.assertEqual(commands[4], ('Q', (29, 42), (32, 46)))
        self.assertEqual(commands[-1], ('Z',))
        self.assertEqual(generator.path_commands('M1 2 3 4h5v6'), [('M', (1, 2)), ('L', (3, 4)), ('L', (8, 4)), ('L', (8, 10))])

    def test_paint_inheritance_and_unsupported_semantics(self):
        svg = ET.fromstring('<g fill="none" stroke="var(--avatar-ink, #000000)" stroke-linecap="round"><path d="M0 0L10 10"/></g>')
        layer = generator.layers(svg)[0]
        self.assertIn('fill: nil, stroke: .ink', layer)
        self.assertIn('lineCap: .round', layer)
        with self.assertRaisesRegex(AssertionError, 'Group opacity'):
            generator.layers(ET.fromstring('<g opacity=".5"><path d="M0 0L10 10"/></g>'))
        with self.assertRaisesRegex(AssertionError, 'Unsupported paint'):
            generator.layers(ET.fromstring('<path d="M0 0L10 10"/>'))

    def test_checked_in_geometry_matches_sources(self):
        self.assertEqual(generator.OUTPUT.read_text(), generator.generate())

    def test_grouped_svgs_preserve_three_original_characters_and_palette_paints(self):
        for name in generator.validation.SHAPES:
            with self.subTest(shape=name):
                original = ET.parse(generator.ROOT / f'{name}.svg').getroot()
                original_layers = generator.layers(original)
                svg = generator.grouped_svg(name)
                self.assertEqual((generator.GROUP_OUTPUT / f'{name}.svg').read_text(), svg)
                grouped = ET.fromstring(svg)
                characters = [child for child in grouped if generator.validation.local_name(child.tag) == 'g']
                self.assertEqual(len(characters), 3)
                self.assertEqual(len(generator.layers(grouped)), len(original_layers) * 3)
                for character, (x, y, scale) in zip(characters, generator.GROUP_PLACEMENTS):
                    self.assertEqual(character.attrib.pop('transform'),
                                     f'translate({generator.number(x)} {generator.number(y)}) scale({generator.number(scale)})')
                    self.assertEqual(generator.layers(character), original_layers)
                    self.assertGreaterEqual(min(x, y), 0)
                    self.assertLessEqual(max(x, y) + 256 * scale, 256)

    def test_grouped_svg_catalog_is_complete_and_passes_authored_subset_validation(self):
        expected = {f'{name}.svg' for name in generator.validation.SHAPES}
        self.assertEqual({path.name for path in generator.GROUP_OUTPUT.glob('*.svg')}, expected)
        with tempfile.TemporaryDirectory() as directory:
            for name in generator.validation.SHAPES:
                path = Path(directory) / f'{name}.svg'
                path.write_text(generator.grouped_svg(name))
                generator.validation.validate_svg(path)

    def test_native_groups_cache_the_same_transforms_as_portable_svgs(self):
        native = generator.generate()
        for x, y, scale in generator.GROUP_PLACEMENTS:
            self.assertIn(f'({generator.number(x)}, {generator.number(y)}, {generator.number(scale)}),', native)
        for name in generator.validation.SHAPES:
            self.assertIn(f'private static let {name}Group = grouped({name})', native)
        self.assertIn('lineWidth: layer.lineWidth * scale', native)

    def test_transform_order_preserves_optical_center_and_scaled_strokes(self):
        point = (128, 128)
        for matrix, _ in reversed(generator.affine_transforms('translate(14.08 14.08) scale(.89)')):
            a, b, c, d, tx, ty = matrix
            x, y = point
            point = (a*x+c*y+tx, b*x+d*y+ty)
        self.assertEqual(point, (128, 128))
        svg = ET.fromstring('<g transform="translate(8.96 8.96) scale(.93)" fill="none"><path transform="rotate(32 89 157)" d="M0 0L10 10" stroke="var(--avatar-ink, #000000)" stroke-width="4.5"/></g>')
        layer = generator.layers(svg)[0]
        self.assertIn('lineWidth: 4.185', layer)
        self.assertLess(layer.index('a: 0.848048'), layer.index('a: 0.93'))
        self.assertLess(layer.index('a: 0.93'), layer.index('tx: 8.96'))
        with self.assertRaisesRegex(AssertionError, 'Nonuniform scale'):
            generator.affine_transforms('scale(1 2)')


if __name__ == '__main__':
    unittest.main()
