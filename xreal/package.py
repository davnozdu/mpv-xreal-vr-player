#!/usr/bin/env python3
"""Build a separately branded, relocatable app using mpv's dependency bundler."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
DIST = ROOT / 'dist'
DIST.mkdir(exist_ok=True)
APP = DIST / 'XREAL VR Player.app'
sys.path.insert(0, str(ROOT / 'TOOLS'))
import dylib_unhell
linked_libraries, _ = dylib_unhell.libraries(str(ROOT / 'build/mpv'))
subprocess.run([sys.executable, 'TOOLS/osxbundle.py', 'build/mpv'], check=True)
if APP.exists():
    shutil.rmtree(APP)
shutil.move('build/mpv.app', APP)
CONTENTS = APP / 'Contents'
MACOS = CONTENTS / 'MacOS'
RESOURCES = CONTENTS / 'Resources'
(MACOS / 'mpv').rename(MACOS / 'xreal-vr-player')
for resource in (ROOT / 'xreal/resources').iterdir():
    shutil.copy2(resource, RESOURCES / resource.name)
shutil.copy2(ROOT / 'xreal/QUICKSTART-RU.md', RESOURCES / 'QUICKSTART-RU.md')
plist = {
    'CFBundleDevelopmentRegion': 'ru', 'CFBundleExecutable': 'xreal-vr-player',
    'CFBundleIdentifier': 'com.davnozdu.xreal-vr-player',
    'CFBundleName': 'XREAL VR Player', 'CFBundleDisplayName': 'XREAL VR Player',
    'CFBundlePackageType': 'APPL', 'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundleShortVersionString': '0.1.1', 'CFBundleVersion': '2',
    'CFBundleIconFile': 'icon', 'NSHighResolutionCapable': True,
    'LSApplicationCategoryType': 'public.app-category.video',
    'LSMinimumSystemVersion': '15.0',
    'LSEnvironment': {'MPVBUNDLE': 'true', 'MallocNanoZone': '0'},
    'CFBundleDocumentTypes': [{
        'CFBundleTypeName': 'Stereo / VR movie', 'CFBundleTypeRole': 'Viewer',
        'LSHandlerRank': 'Alternate',
        'LSItemContentTypes': ['public.movie', 'public.mpeg-4', 'com.apple.quicktime-movie', 'org.matroska.mkv'],
    }],
}
with (CONTENTS / 'Info.plist').open('wb') as f:
    plistlib.dump(plist, f)
licenses = RESOURCES / 'licenses'
licenses.mkdir(exist_ok=True)
for name in ['LICENSE.GPL', 'LICENSE.LGPL', 'Copyright']:
    shutil.copy2(ROOT / name, licenses / name)
# Ship the installed dependency license records along with the linked libraries.
prefix = Path(subprocess.check_output(['brew', '--prefix'], text=True).strip())
versions = set()
for lib in linked_libraries:
    try:
        parts = Path(lib).resolve().relative_to(prefix / 'Cellar').parts
        versions.add(prefix / 'Cellar' / parts[0] / parts[1])
    except ValueError:
        pass
for version in versions:
    files = [f for f in version.iterdir() if f.is_file() and
             (f.name.lower().startswith(('license', 'copying', 'copyright')) or f.name == 'sbom.spdx.json')]
    if files:
        dest = licenses / version.parent.name / version.name
        dest.mkdir(parents=True, exist_ok=True)
        for f in files:
            shutil.copy2(f, dest / f.name)
manifest = {
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'architecture': subprocess.check_output(['uname', '-m'], text=True).strip(),
    'mpv': subprocess.check_output(['build/mpv', '--no-config', '--version'], text=True).strip(),
    'notarized': False,
}
(RESOURCES / 'build-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
shutil.copy2(ROOT / 'xreal/test-output/optimization-audit.json', RESOURCES / 'optimization-audit.json')
# The rename and resources alter the signature; re-sign all Mach-O files.
for f in sorted(MACOS.rglob('*')):
    if f.is_file():
        subprocess.run(['codesign', '--force', '--sign', '-', str(f)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(APP)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True)
# Check relocatability: no library may still link to Homebrew or the workspace.
for f in [MACOS / 'xreal-vr-player', *sorted((MACOS / 'lib').glob('*.dylib'))]:
    linked = subprocess.check_output(['otool', '-L', str(f)], text=True)
    for line in linked.splitlines()[1:]:
        if '/opt/homebrew/' in line or '/usr/local/' in line or str(ROOT) in line:
            raise RuntimeError(f'Unbundled dependency in {f}: {line.strip()}')
subprocess.run([sys.executable, 'xreal/test_bundle.py', str(APP)], check=True)
stage = DIST / 'dmg-stage'
if stage.exists():
    shutil.rmtree(stage)
stage.mkdir()
shutil.copytree(APP, stage / APP.name, symlinks=True)
(stage / 'Applications').symlink_to('/Applications')
shutil.copy2(ROOT / 'xreal/QUICKSTART-RU.md', stage / 'ПРОЧИТАЙТЕ.md')
image = DIST / 'XREAL-VR-Player-arm64.dmg'
if image.exists():
    image.unlink()
subprocess.run(['hdiutil', 'create', '-volname', 'XREAL VR Player', '-srcfolder', str(stage),
                '-format', 'UDZO', str(image)], check=True)
shutil.rmtree(stage)
zip_path = DIST / 'XREAL-VR-Player-arm64.zip'
if zip_path.exists():
    zip_path.unlink()
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(APP), str(zip_path)], check=True)
(DIST / 'SHA256SUMS.txt').write_text(''.join(
    f'{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.name}\n' for f in [image, zip_path]))
print(f'Packaged: {image}')
