#!/usr/bin/env python3
"""Build Wonder's monochrome, transparent menu-bar mark as a vector PDF."""
from pathlib import Path

# A rising sun with rounded rays and transparent facial features. Coordinates
# are menu-bar points, so the vector remains sharp on Retina displays.
art = b'''0 G 0 g 1 J 1 j 1.8 w
12 12.5 m 12 16.5 l S
4.7 10 m 2.9 12 l S
19.3 10 m 21.1 12 l S
1 4 m 3 4 l S
21 4 m 23 4 l S
5 2 m 5 3 l 5 7.14 8.14 10.5 12 10.5 c
15.86 10.5 19 7.14 19 3 c 19 2 l 19 1.45 18.55 1 18 1 c
6 1 l 5.45 1 5 1.45 5 2 c h
8.5 5.2 m 8.5 6.4 l 8.5 7.5 10 7.5 10 6.4 c 10 5.2 l 10 4.1 8.5 4.1 8.5 5.2 c h
14 5.2 m 14 6.4 l 14 7.5 15.5 7.5 15.5 6.4 c 15.5 5.2 l 15.5 4.1 14 4.1 14 5.2 c h
10.2 3.7 m 11.2 2.2 12.8 2.2 13.8 3.7 c
14.2 4.4 13.3 4.8 12.9 4.2 c 12.4 3.5 11.6 3.5 11.1 4.2 c
10.7 4.8 9.8 4.4 10.2 3.7 c h f*
'''
objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
           b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 24 18] /Contents 4 0 R /Resources << >> >>',
           b'<< /Length ' + str(len(art)).encode() + b' >>\nstream\n' + art + b'endstream']
data = bytearray(b'%PDF-1.4\n')
offsets = [0]
for i, obj in enumerate(objects, 1):
    offsets.append(len(data))
    data.extend(f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n')
xref = len(data)
data.extend(b'xref\n0 5\n0000000000 65535 f \n')
for offset in offsets[1:]:
    data.extend(f'{offset:010d} 00000 n \n'.encode())
data.extend(f'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
path = Path(__file__).resolve().parents[1] / 'apps/menubar/Resources/WonderMenuIcon.pdf'
path.write_bytes(data)
print(path)
