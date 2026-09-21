#!/usr/bin/env python3
"""Compile the validated SVG originals to cached SwiftUI paths, never runtime SVG.

Arc conversion follows https://www.w3.org/TR/SVG/implnote.html#ArcImplementationNotes.
Only the authored subset is supported; new features fail rather than silently drift.
"""
import argparse
import copy
import importlib.util
import math
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT.parents[2] / 'apps/ios/Wonder/ScienceAvatarGeometry.swift'
GROUP_OUTPUT = ROOT / 'subagents'
# Two characters behind one centered foreground character. Keep the same
# placement in the portable SVGs and the cached native paths.
GROUP_PLACEMENTS = ((0, 0, .62), (97.28, 0, .62), (48.64, 97.28, .62))
ET.register_namespace('', 'http://www.w3.org/2000/svg')
spec = importlib.util.spec_from_file_location('avatar_validation', ROOT / 'validate-assets.py')
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)
TOKEN = re.compile(r'[A-Za-z]|[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?')


def number(value):
    return f'{0 if abs(value) < 0.0000005 else value:.6f}'.rstrip('0').rstrip('.')


def point(value):
    return f'CGPoint(x: {number(value[0])}, y: {number(value[1])})'


def arc(start, rx, ry, angle, large, sweep, end):
    """SVG endpoint arc to cubic segments of at most 45 degrees."""
    if start == end:
        return []
    rx, ry = abs(rx), abs(ry)
    if not rx or not ry:
        return [('L', end)]
    assert large in (0, 1) and sweep in (0, 1), 'Invalid arc flag'
    phi = math.radians(angle)
    c, s = math.cos(phi), math.sin(phi)
    dx, dy = (start[0]-end[0])/2, (start[1]-end[1])/2
    x, y = c*dx+s*dy, -s*dx+c*dy
    scale = x*x/(rx*rx) + y*y/(ry*ry)
    if scale > 1:
        rx *= math.sqrt(scale)
        ry *= math.sqrt(scale)
    denominator = rx*rx*y*y + ry*ry*x*x
    factor = math.sqrt(max(0, (rx*rx*ry*ry-denominator)/denominator))
    if large == sweep:
        factor = -factor
    cx, cy = factor*rx*y/ry, -factor*ry*x/rx
    center = (c*cx-s*cy+(start[0]+end[0])/2, s*cx+c*cy+(start[1]+end[1])/2)
    u = ((x-cx)/rx, (y-cy)/ry)
    v = ((-x-cx)/rx, (-y-cy)/ry)
    theta = math.atan2(u[1], u[0])
    delta = math.atan2(u[0]*v[1]-u[1]*v[0], u[0]*v[0]+u[1]*v[1])
    if not sweep and delta > 0:
        delta -= 2*math.pi
    elif sweep and delta < 0:
        delta += 2*math.pi
    count = max(1, math.ceil(abs(delta)/(math.pi/4)))
    step = delta/count
    def position(t):
        return (center[0]+rx*c*math.cos(t)-ry*s*math.sin(t), center[1]+rx*s*math.cos(t)+ry*c*math.sin(t))
    def tangent(t):
        return (-rx*c*math.sin(t)-ry*s*math.cos(t), -rx*s*math.sin(t)+ry*c*math.cos(t))
    result = []
    for i in range(count):
        a, b = theta+i*step, theta+(i+1)*step
        alpha = 4/3*math.tan(step/4)
        p, q, dp, dq = position(a), position(b), tangent(a), tangent(b)
        result.append(('C', (p[0]+alpha*dp[0], p[1]+alpha*dp[1]),
                       (q[0]-alpha*dq[0], q[1]-alpha*dq[1]), end if i == count-1 else q))
    return result


def path_commands(data):
    tokens = TOKEN.findall(data)
    current = start = (0.0, 0.0)
    cubic = quad = None
    command = previous = None
    index = 0
    output = []
    counts = {'M': 2, 'L': 2, 'H': 1, 'V': 1, 'C': 6, 'S': 4, 'Q': 4, 'T': 2, 'A': 7}
    while index < len(tokens):
        if tokens[index].isalpha():
            command = tokens[index]
            index += 1
        assert command, 'Path must start with a command'
        kind = command.upper()
        if kind == 'Z':
            output.append(('Z',))
            current = start
            cubic = quad = None
            previous, command = kind, None
            continue
        assert kind in counts, f'Unsupported path command: {command}'
        values = [float(v) for v in tokens[index:index+counts[kind]]]
        assert len(values) == counts[kind], 'Incomplete path command'
        index += counts[kind]
        relative = command.islower()
        def xy(i):
            return (values[i]+(current[0] if relative else 0), values[i+1]+(current[1] if relative else 0))
        next_cubic = next_quad = None
        if kind in ('M', 'L'):
            end = xy(0)
            output.append((kind, end))
            if kind == 'M':
                start = end
                command = 'l' if relative else 'L'
        elif kind == 'H':
            end = (values[0]+(current[0] if relative else 0), current[1])
            output.append(('L', end))
        elif kind == 'V':
            end = (current[0], values[0]+(current[1] if relative else 0))
            output.append(('L', end))
        elif kind in ('C', 'S'):
            first = xy(0) if kind == 'C' else ((2*current[0]-cubic[0], 2*current[1]-cubic[1]) if previous in ('C', 'S') else current)
            second, end = (xy(2), xy(4)) if kind == 'C' else (xy(0), xy(2))
            output.append(('C', first, second, end))
            next_cubic = second
        elif kind in ('Q', 'T'):
            control = xy(0) if kind == 'Q' else ((2*current[0]-quad[0], 2*current[1]-quad[1]) if previous in ('Q', 'T') else current)
            end = xy(2) if kind == 'Q' else xy(0)
            output.append(('Q', control, end))
            next_quad = control
        else:
            end = xy(5)
            output.extend(arc(current, *values[:5], end))
        current, previous, cubic, quad = end, kind, next_cubic, next_quad
    return output


def swift_path(element):
    tag = validation.local_name(element.tag)
    a = element.attrib
    if tag == 'path':
        lines = []
        for command in path_commands(a['d']):
            kind, *p = command
            if kind == 'M': lines.append(f'path.move(to: {point(p[0])})')
            elif kind == 'L': lines.append(f'path.addLine(to: {point(p[0])})')
            elif kind == 'C': lines.append(f'path.addCurve(to: {point(p[2])}, control1: {point(p[0])}, control2: {point(p[1])})')
            elif kind == 'Q': lines.append(f'path.addQuadCurve(to: {point(p[1])}, control: {point(p[0])})')
            else: lines.append('path.closeSubpath()')
        return lines
    if tag in ('circle', 'ellipse'):
        rx = float(a['r'] if tag == 'circle' else a['rx'])
        ry = float(a['r'] if tag == 'circle' else a['ry'])
        rect = (float(a['cx'])-rx, float(a['cy'])-ry, 2*rx, 2*ry)
        return ['path.addEllipse(in: CGRect(x: %s, y: %s, width: %s, height: %s))' % tuple(map(number, rect))]
    if tag == 'rect':
        rect = tuple(float(a.get(k, 0)) for k in ('x', 'y', 'width', 'height'))
        rx, ry = float(a.get('rx', a.get('ry', 0))), float(a.get('ry', a.get('rx', 0)))
        return ['path.addRoundedRect(in: CGRect(x: %s, y: %s, width: %s, height: %s), cornerSize: CGSize(width: %s, height: %s))' % tuple(map(number, (*rect, min(rx, rect[2]/2), min(ry, rect[3]/2))))]
    raise ValueError(f'Unsupported geometry: {tag}')


def affine_transforms(value):
    result = []
    remaining = value.strip()
    while remaining:
        match = re.match(r'(translate|rotate|scale)\(([^()]*)\)', remaining)
        assert match, f'Unsupported transform: {value}'
        values = [float(v) for v in re.split(r'[\s,]+', match[2].strip())]
        assert all(math.isfinite(v) for v in values), f'Nonfinite transform: {value}'
        kind = match[1]
        scale = 1
        if kind == 'translate':
            assert len(values) in (1, 2)
            matrix = (1, 0, 0, 1, values[0], values[1] if len(values) == 2 else 0)
        elif kind == 'scale':
            assert len(values) in (1, 2)
            assert len(values) == 1 or values[0] == values[1], 'Nonuniform scale requires transformed strokes'
            scale = abs(values[0])
            matrix = (values[0], 0, 0, values[0], 0, 0)
        else:
            assert len(values) in (1, 3)
            angle, x, y = values if len(values) == 3 else (values[0], 0, 0)
            c, s = math.cos(math.radians(angle)), math.sin(math.radians(angle))
            matrix = (c, s, -s, c, x-c*x+s*y, y-s*x-c*y)
        result.append((matrix, scale))
        remaining = remaining[match.end():].lstrip(' ,\t\r\n')
    assert result, 'Empty transform'
    return result


def paint(value):
    if value == 'none': return 'nil'
    match = re.fullmatch(r'var\(--avatar-(body|shadow|accent|ink), #[\da-fA-F]{6}\)', value)
    assert match, f'Unsupported paint: {value}'
    return '.' + match[1]


def layers(element, inherited=None, transforms=()):
    attributes = dict(inherited or {'fill': 'black', 'stroke': 'none'})
    attributes.update(element.attrib)
    own = element.attrib
    transforms = transforms + ((own['transform'],) if 'transform' in own else ())
    tag = validation.local_name(element.tag)
    if tag == 'title': return []
    if tag in ('svg', 'g'):
        assert 'opacity' not in own, 'Group opacity requires compositing; do not flatten it'
        attributes.pop('transform', None)
        return [layer for child in element for layer in layers(child, attributes, transforms)]
    commands = swift_path(element)
    line_width = float(attributes.get('stroke-width', 1))
    for transform in reversed(transforms):
        # SVG applies the rightmost function first, then each ancestor transform.
        for matrix, scale in reversed(affine_transforms(transform)):
            swift = 'CGAffineTransform(a: %s, b: %s, c: %s, d: %s, tx: %s, ty: %s)' % tuple(map(number, matrix))
            commands.append(f'path = path.applying({swift})')
            line_width *= scale
    cap = attributes.get('stroke-linecap', 'butt')
    join = attributes.get('stroke-linejoin', 'miter')
    assert cap in ('butt', 'round', 'square') and join in ('miter', 'round', 'bevel')
    return [('            ScienceAvatarVectorLayer(path: {\n                var path = Path()\n'
             + ''.join(f'                {line}\n' for line in commands)
             + '                return path\n            }(), '
             + f'fill: {paint(attributes["fill"])}, stroke: {paint(attributes["stroke"])}, '
             + f'lineWidth: {number(line_width)}, lineCap: .{cap}, lineJoin: .{join}, '
             + f'opacity: {number(float(attributes.get("opacity", 1)))})')]


def grouped_svg(name):
    original = ET.parse(ROOT / f'{name}.svg').getroot()
    namespace = '{http://www.w3.org/2000/svg}'
    title = f'{name.capitalize()} agents'
    root = ET.Element(namespace + 'svg', {'viewBox': '0 0 256 256', 'role': 'img', 'aria-label': title})
    ET.SubElement(root, namespace + 'title').text = title
    for index, (x, y, scale) in enumerate(GROUP_PLACEMENTS):
        group = ET.SubElement(root, namespace + 'g', {
            'data-part': f'agent-{index + 1}',
            'transform': f'translate({number(x)} {number(y)}) scale({number(scale)})',
        })
        for child in original:
            if validation.local_name(child.tag) != 'title':
                group.append(copy.deepcopy(child))
    ET.indent(root, space='  ')
    return ET.tostring(root, encoding='unicode') + '\n'


def generate():
    validation.validate(ROOT)
    result = ['// Generated by assets/bot-avatars/science/generate-ios.py. Do not edit.\n'
              '// Source SHA-256: ' + validation.source_hash(ROOT) + '\n'
              'import SwiftUI\nimport WonderPairing\n\nenum ScienceAvatarGeometry {\n'
              '    static func layers(for shape: ScienceAvatarShape) -> [ScienceAvatarVectorLayer] {\n'
              '        switch shape {\n']
    for name in validation.SHAPES: result.append(f'        case .{name}: {name}\n')
    result.append('        }\n    }\n')
    result.append('\n    static func groupLayers(for shape: ScienceAvatarShape) -> [ScienceAvatarVectorLayer] {\n'
                  '        switch shape {\n')
    for name in validation.SHAPES: result.append(f'        case .{name}: {name}Group\n')
    result.append('        }\n    }\n\n'
                  '    private static func grouped(_ layers: [ScienceAvatarVectorLayer]) -> [ScienceAvatarVectorLayer] {\n'
                  '        let placements: [(CGFloat, CGFloat, CGFloat)] = [\n')
    for x, y, scale in GROUP_PLACEMENTS:
        result.append(f'            ({number(x)}, {number(y)}, {number(scale)}),\n')
    result.append('        ]\n'
                  '        return placements.flatMap { x, y, scale in\n'
                  '            let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y)\n'
                  '            return layers.map { layer in\n'
                  '                ScienceAvatarVectorLayer(path: layer.path.applying(transform),\n'
                  '                    fill: layer.fill, stroke: layer.stroke, lineWidth: layer.lineWidth * scale,\n'
                  '                    lineCap: layer.lineCap, lineJoin: layer.lineJoin, opacity: layer.opacity)\n'
                  '            }\n'
                  '        }\n'
                  '    }\n')
    for name in validation.SHAPES:
        result.append(f'\n    private static let {name}Group = grouped({name})\n')
    for name in validation.SHAPES:
        result.append(f'\n    private static let {name}: [ScienceAvatarVectorLayer] = [\n')
        result.append(',\n'.join(layers(ET.parse(ROOT / f'{name}.svg').getroot())))
        result.append('\n    ]\n')
    result.append('}\n')
    return ''.join(result)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    generated = generate()
    groups = {GROUP_OUTPUT / f'{name}.svg': grouped_svg(name) for name in validation.SHAPES}
    if args.check:
        assert OUTPUT.read_text() == generated, 'Native geometry is stale; run generate-ios.py'
        assert set(GROUP_OUTPUT.glob('*.svg')) == set(groups), 'Expected exactly seven grouped SVGs'
        for path, svg in groups.items():
            assert path.read_text() == svg, f'{path.name} group is stale; run generate-ios.py'
            validation.validate_svg(path)
        print('Native avatar geometry and seven grouped SVGs match the validated originals.')
    else:
        OUTPUT.write_text(generated)
        GROUP_OUTPUT.mkdir(exist_ok=True)
        for path, svg in groups.items():
            path.write_text(svg)
            validation.validate_svg(path)
        print(OUTPUT)
