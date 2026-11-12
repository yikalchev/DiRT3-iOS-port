#!/usr/bin/env python3
"""Build the DiRT 3 native engine for iOS and export CMake's link line to Xcode.

Run by the DIRT3 target's "Build DiRT 3 native runtime" phase. CMake compiles the
lifted game code and the ps3recomp runtime into libDIRT3Recomp.a; Xcode compiles
the UIKit entry point and links that archive through build/ios/<sdk>/xcode-link.rsp.
The launch environment and the expected game-file manifest are written into the
app bundle as DIRT3Launch.json. Game data is never bundled into the app.
"""
import fcntl
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

TITLE = '[AS] DiRT 3'


def write_changed(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text() != contents:
        path.write_text(contents)


def main():
    root = Path(__file__).resolve().parents[1]
    game = Path(os.environ.get('DIRT3_GAME_DIR', str(root / 'game'))).resolve()
    recomp_dir = root / 'port/recompiled'
    spu_dir = root / 'port/spu'
    platform = os.environ.get('PLATFORM_NAME')
    if platform not in ('iphoneos', 'iphonesimulator'):
        sys.exit('error: DIRT3 builds for iOS only (iphoneos or iphonesimulator).')
    diagnostics = os.environ.get('DIRT3_DIAGNOSTICS', '1') == '1'

    for required in (root / 'vendor/ps3recomp/CMakeLists.txt', recomp_dir / 'ppu_recomp.h',
                     spu_dir / 'spu_workloads.c', game / 'PS3_GAME/USRDIR/EBOOT.elf',
                     game / 'PS3_GAME/PARAM.SFO'):
        if not required.is_file():
            sys.exit(f'error: Missing {required}. See README.md (tools/bootstrap_runtime.py, '
                     'tools/analyze_dirt3.sh and the game/ folder).')

    build = root / 'build/ios' / platform
    build.mkdir(parents=True, exist_ok=True)
    with (build / '.xcode-build.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        query = build / '.cmake/api/v1/query/client-dirt3/codemodel-v2'
        query.parent.mkdir(parents=True, exist_ok=True)
        query.touch()

        deps = root / 'build/ios-deps' / platform
        prefix = deps / 'install'
        manifest = json.loads((root / 'port/ios/dependencies.json').read_text())
        ready = deps / 'ready.json'
        if not ready.exists() or json.loads(ready.read_text()).get('dependencies') != manifest:
            sys.exit(f'error: First run python3 tools/build_ios_dependencies.py --sdk {platform}')
        sdk = subprocess.check_output(['xcrun', '--sdk', platform, '--show-sdk-path'], text=True).strip()
        subprocess.run(['cmake', '-S', str(root / 'port'), '-B', str(build), '-G', 'Ninja',
            '-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_SYSTEM_PROCESSOR=arm64',
            f'-DCMAKE_OSX_SYSROOT={sdk}', '-DCMAKE_OSX_ARCHITECTURES=arm64',
            '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0', '-DCMAKE_BUILD_TYPE=Release',
            '-DDIRT3_IOS_DIAGNOSTICS=' + ('ON' if diagnostics else 'OFF'),
            f'-DCMAKE_PREFIX_PATH={prefix}', f'-DCMAKE_FIND_ROOT_PATH={prefix}',
            '-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY', '-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY',
            '-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY', '-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER',
            '-DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON',
            f'-DRECOMP_DIR={recomp_dir}', f'-DSPU_DIR={spu_dir}',
            f'-DSDL2_DIR={prefix}/lib/cmake/SDL2', f'-Dglslang_DIR={prefix}/lib/cmake/glslang',
            f'-DSPVC_INC_DIR={prefix}/include/spirv_cross', f'-DSPVC_LIB={prefix}/lib/libspirv-cross-c.a',
            f'-DPS3RECOMP_DIR={root}/vendor/ps3recomp', '-DPS3RECOMP_FFMPEG_RUNTIME=ON',
            f'-DPS3RECOMP_FFMPEG_INCLUDE_DIR={prefix}/include'], check=True)
        subprocess.run(['cmake', '--build', str(build), '--target', 'DIRT3Recomp',
            '-j', os.environ.get('BUILD_JOBS', '6')], check=True)

        # Export the runner's link line (libraries and search paths) for Xcode.
        reply = build / '.cmake/api/v1/reply'
        index = json.loads(max(reply.glob('index-*.json'), key=lambda p: p.stat().st_mtime).read_text())
        model_ref = index['reply']['client-dirt3']['codemodel-v2']['jsonFile']
        model = json.loads((reply / model_ref).read_text())
        target_ref = next(t for t in model['configurations'][0]['targets'] if t['name'] == 'dirt3_runner')
        target = json.loads((reply / target_ref['jsonFile']).read_text())
        args = []
        for fragment in target['link']['commandFragments']:
            if fragment['role'] not in ('libraries', 'libraryPath', 'frameworkPath'):
                continue
            for arg in shlex.split(fragment['fragment']):
                if not arg.startswith('-') and arg.endswith(('.a', '.dylib')) and not Path(arg).is_absolute():
                    arg = str(build / arg)
                args.append(arg)
        if not any(arg.endswith('/libDIRT3Recomp.a') for arg in args):
            sys.exit('error: CMake did not export the native game archive.')
        response = '\n'.join('"' + arg.replace('\\', '\\\\').replace('"', '\\"') + '"' for arg in args) + '\n'
        write_changed(build / 'xcode-link.rsp', response)

        values = json.loads((root / 'port/ios/dirt3-runtime-options.json').read_text())
        values['PS3_TITLE'] = TITLE
        if diagnostics:
            values['PS3RECOMP_METAL_FPS'] = '1'
        # The app accepts Documents/game only when every file the game ships
        # in PS3_GAME is present with the expected size.
        files = {p.relative_to(game).as_posix(): p.stat().st_size
                 for p in sorted((game / 'PS3_GAME').rglob('*')) if p.is_file()
                 and not any(part.startswith('.') for part in p.relative_to(game).parts)}
        config = {'environment': values, 'files': files,
                  'build_options': {'offline_diagnostics': diagnostics}}
        resources = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']
        write_changed(resources / 'DIRT3Launch.json', json.dumps(config, indent=2, ensure_ascii=False) + '\n')
        print(f'DiRT 3 native runtime ready for {platform}; game data is not bundled into the app.')


if __name__ == '__main__':
    main()
