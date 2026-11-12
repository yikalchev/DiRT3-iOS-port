#!/usr/bin/env python3
"""Build pinned, static iOS dependencies without using macOS Homebrew binaries."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', choices=['iphoneos', 'iphonesimulator'], default='iphoneos')
    parser.add_argument('--jobs', default='4')
    args = parser.parse_args()
    # Follow `xcode-select` when no per-process override is supplied. Hard-coding
    # /Applications/Xcode.app breaks installations kept under another directory
    # (for example /Applications/Utils/Xcode.app).
    if not os.environ.get('DEVELOPER_DIR'):
        selected = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
        if not Path(selected).is_dir():
            raise SystemExit(f'xcode-select points to a missing Developer directory: {selected}')
        os.environ['DEVELOPER_DIR'] = selected
    source = ROOT / 'vendor/ios-deps'
    source.mkdir(parents=True, exist_ok=True)
    dependencies = json.loads((ROOT / 'port/ios/dependencies.json').read_text())
    for name, spec in dependencies.items():
        dest = source / name
        stamp = dest / '.dirt3-revision'
        if stamp.exists() and stamp.read_text().strip() == spec['commit']:
            continue
        if dest.exists() and any(dest.iterdir()):
            raise SystemExit(f'Refusing to overwrite unrecognized dependency: {dest}')
        url = f"https://codeload.github.com/{spec['repo']}/tar.gz/{spec['commit']}"
        print(f'Downloading {name} at {spec["commit"]}', flush=True)
        with tempfile.TemporaryDirectory(dir=source) as temp:
            archive = Path(temp) / 'source.tar.gz'
            urllib.request.urlretrieve(url, archive)
            with tarfile.open(archive) as tar:
                tar.extractall(Path(temp) / 'unpacked', filter='data')
            # GitHub archives hold one top-level folder; some also carry a stray
            # top-level file (glslang), so take the single directory.
            entries = list((Path(temp) / 'unpacked').iterdir())
            dirs = [e for e in entries if e.is_dir()]
            if len(dirs) != 1:
                raise SystemExit(f'{name}: expected one top-level folder, got {[e.name for e in entries]}')
            unpacked = dirs[0]
            dest.parent.mkdir(parents=True, exist_ok=True)
            if dest.exists(): dest.rmdir()  # upstream empty dependency placeholder
            shutil.move(unpacked, dest)
            stamp.write_text(spec['commit'] + '\n')
    build = ROOT / 'build/ios-deps' / args.sdk
    prefix = build / 'install'
    sdk = subprocess.check_output(['xcrun', '--sdk', args.sdk, '--show-sdk-path'], text=True).strip()
    run(['cmake', '-S', ROOT / 'port/ios/deps', '-B', build / 'cmake', '-G', 'Ninja',
         '-DCMAKE_SYSTEM_NAME=iOS', f'-DCMAKE_OSX_SYSROOT={sdk}', '-DCMAKE_OSX_ARCHITECTURES=arm64',
         '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0', '-DCMAKE_BUILD_TYPE=Release',
         f'-DCMAKE_INSTALL_PREFIX={prefix}', f'-DIOS_SOURCE_DIR={source}'])
    run(['cmake', '--build', build / 'cmake', '--target', 'install', '-j', args.jobs])
    # FFmpeg's configure rejects out-of-tree builds when its source path has
    # whitespace. Stage both the source and build tree in a short, whitespace-
    # free temp directory. Install into a temporary prefix there, then merge the
    # artifacts into our project prefix.
    temp_root = Path(tempfile.gettempdir())
    if any(c.isspace() for c in str(temp_root)):
        temp_root = Path('/private/tmp') if Path('/private/tmp').is_dir() else Path('/tmp')
    if any(c.isspace() for c in str(temp_root)):
        raise SystemExit(f'FFmpeg needs a temporary path without spaces: {temp_root}')
    target = 'arm64-apple-ios18.0' + ('-simulator' if args.sdk == 'iphonesimulator' else '')
    flags = f'-target {target} -isysroot {sdk}'
    with tempfile.TemporaryDirectory(prefix='ios_ffmpeg_', dir=temp_root) as temp:
        work = Path(temp)
        ffmpeg_source = work / 'source'
        ffmpeg_build = work / 'build'
        ffmpeg_prefix = work / 'install'
        shutil.copytree(source / 'ffmpeg', ffmpeg_source, symlinks=True,
                        ignore=shutil.ignore_patterns('.git', 'config.log',
                                                      'config.mak', 'config.h'))
        ffmpeg_build.mkdir()
        try:
            run([ffmpeg_source / 'configure', f'--prefix={ffmpeg_prefix}', '--target-os=darwin',
                 '--arch=aarch64', '--enable-cross-compile', f'--sysroot={sdk}', '--cc=clang',
                 f'--extra-cflags={flags}', f'--extra-ldflags={flags}', '--disable-everything',
                 '--disable-programs', '--disable-doc', '--disable-debug', '--disable-autodetect',
                 '--disable-shared', '--enable-static', '--enable-pic', '--enable-avcodec', '--enable-avutil',
                 '--enable-decoder=h264,mpeg2video,mp3,mp3float,aac,atrac3,atrac3p,pcm_s16be,pcm_s16le',
                 '--enable-parser=h264,mpegvideo,mpegaudio,aac', '--enable-pthreads'], cwd=ffmpeg_build)
            run(['make', '-j', args.jobs], cwd=ffmpeg_build)
            run(['make', 'install'], cwd=ffmpeg_build)
        except Exception:
            config_log = ffmpeg_build / 'ffbuild/config.log'
            if config_log.is_file():
                kept_log = build / 'ffmpeg-config.log'
                shutil.copy2(config_log, kept_log)
                print(f'FFmpeg configure log saved to: {kept_log}', file=sys.stderr)
            raise
        prefix.mkdir(parents=True, exist_ok=True)
        for item in ffmpeg_prefix.iterdir():
            destination = prefix / item.name
            if item.is_dir():
                shutil.copytree(item, destination, dirs_exist_ok=True, symlinks=True)
            else:
                shutil.copy2(item, destination)
    (build / 'ready.json').write_text(json.dumps({'sdk': args.sdk, 'dependencies': dependencies}, indent=2))
    print(f'iOS dependencies ready: {prefix}')


if __name__ == '__main__':
    main()
