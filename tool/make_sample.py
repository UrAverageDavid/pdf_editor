"""Generate deterministic PDF fixtures without external libraries.

The default document is bundled. --pages 327 produces a large manual-test PDF.
"""
import argparse
from pathlib import Path


def escaped(text):
    return text.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')


def make_pdf(count):
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>']
    pages = []
    for index in range(count):
        page_id = len(objects) + 1
        pages.append(page_id)
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
                       f'/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> '
                       f'/Contents {page_id + 1} 0 R >>'.encode())
        commands = ['0.99 0.99 0.98 rg 0 0 612 792 re f',
                    '0.16 0.28 0.78 rg 48 734 24 4 re f']

        def text(x, y, size, message, bold=False, color='0.14 0.17 0.21'):
            commands.append(f'{color} rg BT /F{2 if bold else 1} {size} Tf '
                            f'{x} {y} Td ({escaped(message)}) Tj ET')

        text(84, 731, 10, 'PAPERTRAIL  /  PRACTICE DOCUMENT', color='0.45 0.48 0.44')
        if index == 0:
            text(48, 657, 36, 'A little room to think.', True)
            text(48, 623, 13, 'Make this page your own. Your notes are saved as you go.')
            text(48, 559, 11, '01    TRY YOUR PEN', True, '0.16 0.28 0.78')
            text(48, 536, 12, 'Write a thought, circle a word, or sketch an idea below.')
            for y in range(490, 320, -28):
                commands.append(f'0.86 0.88 0.85 RG 0.5 w 48 {y} m 564 {y} l S')
            text(48, 283, 11, '02    GET COMFORTABLE', True, '0.16 0.28 0.78')
            for y, line in zip([256, 232, 208, 184], [
                'Pen or mouse: draw. Touch: scroll and pinch to zoom.',
                'Eraser removes a whole stroke. Undo brings it right back.',
                'Use the Hand tool to drag the page with your mouse.',
                'Go back to your documents, then reopen to see your notes.']):
                text(48, y, 12, line)
            text(48, 125, 10, 'Your original PDF stays untouched.', color='0.45 0.48 0.44')
        else:
            text(48, 657, 32, 'Let an idea take shape.', True)
            text(48, 623, 13, 'A blank page for the next thought.')
            commands.append('0.84 0.86 0.83 rg')
            for x in range(48, 565, 18):
                for y in range(110, 590, 18):
                    commands.append(f'{x} {y} 0.9 0.9 re f')
        text(48, 42, 9, 'YOUR PDF. YOUR HANDWRITING.', color='0.45 0.48 0.44')
        text(536, 42, 9, f'{index + 1:02d}', color='0.45 0.48 0.44')
        content = '\n'.join(commands).encode('ascii')
        objects.append(f'<< /Length {len(content)} >>\nstream\n'.encode() + content + b'\nendstream')
    objects[1] = f'<< /Type /Pages /Count {count} /Kids [{" ".join(f"{i} 0 R" for i in pages)}] >>'.encode()
    result = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(result))
        result.extend(f'{index} 0 obj\n'.encode() + obj + b'\nendobj\n')
    xref = len(result)
    result.extend(f'xref\n0 {len(objects) + 1}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]:
        result.extend(f'{offset:010d} 00000 n \n'.encode())
    result.extend(f'trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--pages', type=int, default=3)
    parser.add_argument('--output', default='assets/welcome.pdf')
    args = parser.parse_args()
    if args.pages < 1:
        parser.error('--pages must be positive')
    Path(args.output).write_bytes(make_pdf(args.pages))
    print(f'Wrote {args.pages} pages to {args.output}')
