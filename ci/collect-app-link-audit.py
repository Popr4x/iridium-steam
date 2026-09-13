#!/usr/bin/env python3
"""Record the app's native binaries without distributing executable payloads."""
import hashlib
import argparse
import importlib.util
import json
import re
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('packager', Path(__file__).with_name('package-unsigned-ipa.py'))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def static_inputs(maps, root):
    """Hash the actual archives named by the linker; this is not license approval."""
    records = []
    for link_map in sorted(maps):
        objects = {}
        # Symbol names later in Apple's maps can contain non-UTF-8 bytes.
        # Only the object-file table contains archive inputs.
        table = link_map.read_bytes().split(b'# Sections:', 1)[0].decode('utf-8')
        for line in table.splitlines():
            match = re.fullmatch(r'\[\s*\d+\]\s+(.+\.a)\((.+)\)', line)
            if match:
                objects.setdefault(match[1], []).append(match[2])
        for name, members in sorted(objects.items()):
            path = Path(name)
            if not path.is_absolute():
                path = root / path
            path = path.resolve(strict=True)
            with path.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            # Keep machine-specific paths out of the report.
            label = str(path.relative_to(root)) if path.is_relative_to(root) else path.name
            records.append({'link_map': link_map.name,
                            'link_map_sha256': hashlib.sha256(link_map.read_bytes()).hexdigest(),
                            'archive': label,
                            'sha256': digest, 'members': members})
    return records


def inventory(app):
    packager.check_payload(app)
    records = []
    for path in sorted(app.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
            if magic in packager.MACHO:
                kind = 'Mach-O'
            elif magic == b'\x7fELF':
                kind = 'ELF'
            elif magic[:2] == b'MZ':
                stream.seek(60)
                offset = stream.read(4)
                kind = 'DOS'
                if len(offset) == 4:
                    stream.seek(int.from_bytes(offset, 'little'))
                    if stream.read(4) == b'PE\0\0':
                        kind = 'PE'
            else:
                continue
            stream.seek(0)
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        linked = subprocess.check_output(['xcrun', 'otool', '-L', str(path)], text=True) if kind == 'Mach-O' else None
        records.append({'path': str(path.relative_to(app)), 'sha256': digest,
                        'bytes': path.stat().st_size, 'format': kind,
                        'linked_libraries': linked.replace(str(app), 'Iridium.app').splitlines()[1:] if linked is not None else None})
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--link-maps', type=Path)
    args = parser.parse_args()
    app, output = args.app, args.output
    records = inventory(app.resolve())
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(records, indent=2) + '\n')
    if args.link_maps:
        maps = list(args.link_maps.rglob('*LinkMap*.txt'))
        if not maps:
            raise ValueError('No final link maps found')
        inputs = static_inputs(maps, Path.cwd().resolve())
        output.with_name('static-inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    print(f'Recorded {len(records)} native binaries. Static dependencies require link-map review.')
