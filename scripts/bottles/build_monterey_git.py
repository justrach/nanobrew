#!/usr/bin/env python3
"""Build a checksum-pinned Intel Git stack on a disposable native macOS runner.

No publishing. Produces bottles, matching source, an opt-in registry and
build/install evidence. macOS 12 is a deployment target, not a runtime test.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
DIST = ROOT / 'dist/monterey'
RECIPES = json.loads(Path(__file__).with_name('monterey-git-recipes.json').read_text())
PREFIX = Path('/opt/nanobrew/prefix')
ROOTS = ['expat', 'json-c', 'readline', 'pcre2', 'libxml2', 'libssh2', 'openldap', 'curl', 'git']


def order(names):
    result, visiting = [], set()
    def visit(name):
        if name in result:
            return
        if name in visiting:
            raise ValueError('Dependency cycle: ' + name)
        visiting.add(name)
        for dep in RECIPES[name]['dependencies']:
            visit(dep)
        visiting.remove(name)
        result.append(name)
    for name in names:
        visit(name)
    return result


def keg(name):
    return PREFIX / 'Cellar' / name / RECIPES[name]['version']


def download(url, digest):
    with urllib.request.urlopen(url, timeout=180) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError('Checksum mismatch: ' + url)
    return data


def run(args, cwd, env):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def environment(name):
    deps = order(RECIPES[name]['dependencies'])
    env = {k: os.environ[k] for k in ('HOME', 'TMPDIR') if k in os.environ}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', CC='/usr/bin/clang', CXX='/usr/bin/clang++',
               CFLAGS='-O2 -arch x86_64 -mmacosx-version-min=12.0',
               CXXFLAGS='-O2 -arch x86_64 -mmacosx-version-min=12.0',
               MACOSX_DEPLOYMENT_TARGET='12.0', VERBOSE='1',
               CPPFLAGS=' '.join('-I' + str(keg(d) / 'include') for d in deps),
               LDFLAGS='-arch x86_64 -mmacosx-version-min=12.0 ' + ' '.join('-L' + str(keg(d) / 'lib') for d in deps),
               PKG_CONFIG_LIBDIR=':'.join(str(keg(d) / 'lib/pkgconfig') for d in deps))
    return env


def deployment_targets(load_commands):
    targets, command = [], None
    for line in load_commands.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        key, value = fields
        if key == 'cmd':
            command = value
        elif (command == 'LC_BUILD_VERSION' and key == 'minos') or (command == 'LC_VERSION_MIN_MACOSX' and key == 'version'):
            targets.append(value)
    return targets


def audit(keg_path):
    """Reject ARM payloads, newer deployment targets and foreign dylibs."""
    checked = []
    for path in sorted(keg_path.rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
            continue
        subprocess.run(['/usr/bin/lipo', str(path), '-verify_arch', 'x86_64'], check=True)
        load = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
        versions = deployment_targets(load)
        # Ignore SDK, linker/tool and source versions inside other load commands.
        if not versions or any(tuple(map(int, v.split('.'))) > (12, 0, 0) for v in versions):
            raise ValueError(f'Unexpected deployment target for {path}: {versions}')
        links = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
        for line in links.splitlines()[1:]:
            target = line.strip().split(' (')[0]
            if not target.startswith(('/usr/lib/', '/System/Library/', str(PREFIX) + '/', '@rpath/', '@loader_path/', '@executable_path/')):
                raise ValueError(f'Foreign library in {path}: {target}')
        checked.append(str(path.relative_to(keg_path)))
    if not checked:
        raise ValueError('No Mach-O payload found: ' + str(keg_path))
    return checked


def build(name, cmake):
    recipe = RECIPES[name]
    env = environment(name)
    target = keg(name)
    if target.exists():
        raise ValueError('Refusing to overwrite existing keg: ' + str(target))
    data = download(recipe['url'], recipe['sha256'])
    # Keep the actual archive extension, including xz sources.
    suffix = '.tar.xz' if recipe['url'].endswith('.xz') else '.tar.gz'
    (DIST / f'{name}-{recipe["version"]}.upstream{suffix}').write_bytes(data)
    commands = []
    with tempfile.TemporaryDirectory(prefix='nb-monterey-') as td:
        work = Path(td)
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            archive.extractall(work, filter='data')
        dirs = [p for p in work.iterdir() if p.is_dir()]
        if len(dirs) != 1:
            raise ValueError('Expected one source directory')
        src = dirs[0]
        def call(*args):
            commands.append(list(map(str, args)))
            run(args, src, env)
        # The libxml2 release tarball omits helpers present in its matching tag.
        # Restore checksum-pinned upstream test code instead of skipping tests.
        for helper in recipe.get('test_files', []):
            path = DIST / helper['url'].rsplit('/', 1)[-1]
            path.write_bytes(download(helper['url'], helper['sha256']))
            shutil.copyfile(path, src / path.name)
        for patch in [*recipe.get('patches', []), *recipe.get('local_patches', [])]:
            if 'file' in patch:
                local = Path(__file__).parent / patch['file']
                patch_data = local.read_bytes()
                if hashlib.sha256(patch_data).hexdigest() != patch['sha256']:
                    raise ValueError('Local patch checksum mismatch')
                path = DIST / local.name
            else:
                path = DIST / patch['url'].rsplit('/', 1)[-1]
                patch_data = download(patch['url'], patch['sha256'])
            path.write_bytes(patch_data)
            call('/usr/bin/patch', '-p' + str(patch.get('strip', 0)), '-i', path)
        if name in ('expat', 'json-c', 'pcre2', 'libxml2', 'libssh2'):
            opts = {
                'expat': ['-DEXPAT_BUILD_TESTS=ON', '-DEXPAT_BUILD_EXAMPLES=OFF'],
                'json-c': ['-DBUILD_TESTING=ON'],
                'pcre2': ['-DPCRE2_BUILD_PCRE2_16=ON', '-DPCRE2_BUILD_PCRE2_32=ON', '-DPCRE2_SUPPORT_JIT=ON', '-DPCRE2_SUPPORT_LIBREADLINE=OFF'],
                'libxml2': ['-DLIBXML2_WITH_PYTHON=OFF', '-DLIBXML2_WITH_READLINE=ON', '-DLIBXML2_WITH_ZLIB=ON'],
                'libssh2': ['-DRUN_DOCKER_TESTS=OFF', '-DRUN_SSHD_TESTS=ON', '-DCRYPTO_BACKEND=OpenSSL', '-DOPENSSL_ROOT_DIR=' + str(keg('openssl@3'))],
            }[name]
            call(cmake, '-S', '.', '-B', 'build', '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=ON',
                 '-DCMAKE_INSTALL_PREFIX=' + str(target), '-DCMAKE_OSX_ARCHITECTURES=x86_64',
                 '-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0', '-DCMAKE_INSTALL_LIBDIR=lib',
                 '-DCMAKE_INSTALL_NAME_DIR=' + str(target / 'lib'),
                 '-DCMAKE_INSTALL_RPATH=' + ';'.join(str(keg(d) / 'lib') for d in [name, *order(recipe['dependencies'])]),
                 '-DCMAKE_PREFIX_PATH=' + ';'.join(str(keg(d)) for d in order(recipe['dependencies'])),
                 '-DCMAKE_IGNORE_PREFIX_PATH=/usr/local;/opt/homebrew', *opts)
            call(cmake, '--build', 'build', '--parallel', '4')
            ctest = str(Path(cmake).with_name('ctest'))
            call(ctest, '--test-dir', 'build', '--output-on-failure', '--parallel', '4')
            call(cmake, '--install', 'build')
        elif name == 'openssl@3':
            call('/usr/bin/perl', './Configure', 'darwin64-x86_64-cc', 'shared', '--prefix=' + str(target),
                 '--openssldir=/etc/ssl', '--libdir=lib')
            call('make', '-j4')
            call('make', 'test', 'HARNESS_JOBS=4')
            call('make', 'install_sw')
        elif name == 'git':
            args = ['prefix=' + str(target), 'NO_GETTEXT=YesPlease', 'NO_TCLTK=YesPlease',
                    'USE_LIBPCRE2=YesPlease', 'LIBPCREDIR=' + str(keg('pcre2')),
                    'CURLDIR=' + str(keg('curl')), 'CURL_CONFIG=' + str(keg('curl') / 'bin/curl-config'), 'EXPATDIR=' + str(keg('expat')), 'ZLIB_PATH=' + str(keg('zlib')),
                    'NO_INSTALL_HARDLINKS=YesPlease']
            call('make', '-j4', *args)
            call('make', 'install', *args)
        else:
            flags = {
                'zlib': [],
                'readline': ['--with-curses'],
                'openldap': ['--disable-slapd', '--without-cyrus-sasl', '--with-tls=openssl'],
                'curl': ['--with-openssl=' + str(keg('openssl@3')), '--with-zlib=' + str(keg('zlib')),
                         '--with-libssh2=' + str(keg('libssh2')), '--with-ca-bundle=/etc/ssl/cert.pem',
                         '--without-libpsl', '--without-brotli', '--without-zstd', '--without-libidn2',
                         '--without-nghttp2', '--without-nghttp3', '--without-ngtcp2', '--disable-ldap'],
            }[name]
            call('./configure', '--prefix=' + str(target), *flags)
            call('make', '-j4')
            if name == 'zlib':
                call('make', 'test')
            call('make', 'install')
        license_dir = target / 'share/licenses' / name
        for path in src.rglob('*'):
            if path.is_file() and path.name.upper().startswith(('LICENSE', 'COPYING', 'COPYRIGHT')):
                out = license_dir / path.relative_to(src)
                out.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, out)
        if not license_dir.exists():
            raise ValueError('No license notices collected for ' + name)
    checked = audit(target)
    bottle = DIST / f'{name}-{recipe["version"]}.monterey.bottle.tar.gz'
    with bottle.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w') as archive:
            for path in sorted(target.rglob('*')):
                info = archive.gettarinfo(path, f'{name}/{recipe["version"]}/{path.relative_to(target)}')
                info.uid = info.gid = info.mtime = 0
                info.uname = info.gname = ''
                if info.isfile():
                    with path.open('rb') as stream:
                        archive.addfile(info, stream)
                else:
                    archive.addfile(info)
    digest = hashlib.sha256(bottle.read_bytes()).hexdigest()
    evidence = {**recipe, 'package': name, 'bottle_sha256': digest, 'build_commands': commands,
                'deployment_target': '12.0', 'tested_os': platform.mac_ver()[0], 'host_arch': platform.machine(),
                'audited_macho_files': checked, 'monterey_runtime_tested': False}
    bottle.with_suffix('.json').write_text(json.dumps(evidence, indent=2) + '\n')
    return {'token': name, 'name': name, 'kind': 'formula', 'homepage': recipe['homepage'],
            'desc': recipe['description'], 'dependencies': recipe['dependencies'],
            'upstream': {'type': 'homebrew_bottle', 'verified': True}, 'verification': {'sha256': 'required'},
            'resolved': {'version': recipe['version'], 'assets': {'macos-x86_64': {
                'url': 'https://example.invalid/monterey/' + bottle.name, 'sha256': digest, 'minimum_macos_major': 12}}}}


def smoke():
    env = environment('git')
    commands = [('expat', 'xmlwf', '-v'), ('pcre2', 'pcre2grep', '-V'), ('libxml2', 'xmllint', '--version'),
                ('openldap', 'ldapsearch', '-VV'), ('curl', 'curl', '--version'), ('git', 'git', '--version')]
    for name, binary, arg in commands:
        run([keg(name) / 'bin' / binary, arg], DIST, env)
    with tempfile.TemporaryDirectory(prefix='nb-git-smoke-') as td:
        work = Path(td)
        git = keg('git') / 'bin/git'
        run([git, 'init', '.'], work, env)
        (work / 'hello.txt').write_text('Intel package support\n')
        run([git, 'add', 'hello.txt'], work, env)
        run([git, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'smoke'], work, env)
        run([git, 'grep', '-P', 'Intel.*support'], work, env)
        run([git, 'fsck', '--full'], work, env)
        run([git, 'ls-remote', 'https://github.com/justrach/nanobrew.git', 'HEAD'], work, env)
        run([keg('curl') / 'bin/curl', '--fail', '--max-time', '60', '-I', 'https://github.com'], work, env)
        # Exercise libraries that do not ship a CLI, not just version strings.
        for name, body, libs in [
            ('json-c', '#include <json-c/json.h>\nint main(void){struct json_object *o=json_tokener_parse("{\\"v\\":1}"); if(!o)return 1;json_object_put(o);return 0;}', ['json-c']),
            ('readline', '#include <stdio.h>\n#include <readline/readline.h>\nint main(void){return rl_initialize();}', ['readline']),
            ('libssh2', '#include <libssh2.h>\nint main(void){int r=libssh2_init(0);libssh2_exit();return r;}', ['ssh2']),
        ]:
            source = work / 'consumer.c'; source.write_text(body)
            run(['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=12.0', '-I' + str(keg(name) / 'include'),
                 '-L' + str(keg(name) / 'lib'), source, *['-l' + x for x in libs], '-o', work / 'consumer'], work, env)
            run([work / 'consumer'], work, env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cmake', default=shutil.which('cmake'))
    parser.add_argument('--verify-install', action='store_true')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'x86_64' or os.environ.get('GITHUB_ACTIONS') != 'true':
        raise SystemExit('This writes test kegs and requires a disposable GitHub Actions Intel macOS runner')
    DIST.mkdir(parents=True, exist_ok=True)
    if args.verify_install:
        smoke()
        state = Path('/opt/nanobrew/db/state.json').read_text()
        for record in json.loads((DIST / 'registry.json').read_text())['records']:
            digest = record['resolved']['assets']['macos-x86_64']['sha256']
            if digest not in state:
                raise ValueError('Installed digest missing: ' + record['token'])
        (DIST / 'installed-tests.json').write_text(json.dumps({'tested_os': platform.mac_ver()[0],
             'packages': order(ROOTS), 'checks': ['exact installed digests', 'Mach-O target audit at build', 'CLI and library consumers', 'Git commit/grep/fsck', 'Git HTTPS ls-remote', 'curl HTTPS'],
             'monterey_runtime_tested': False}, indent=2) + '\n')
        return
    if not args.cmake:
        raise SystemExit('CMake is required as a build tool')
    records, failures = [], {}
    for name in order(ROOTS):
        failed_deps = [dep for dep in RECIPES[name]['dependencies'] if dep in failures]
        if failed_deps:
            failures[name] = 'Blocked by: ' + ', '.join(failed_deps)
            continue
        try:
            records.append(build(name, str(Path(args.cmake).resolve())))
            print(f'::notice::{name}: built and deployment target audited', flush=True)
        except Exception as exc:
            failures[name] = str(exc)
            print(f'::error::{name}: {exc}', flush=True)
        (DIST / 'build-status.json').write_text(json.dumps({'built': [r['token'] for r in records], 'failures': failures}, indent=2) + '\n')
    if failures:
        raise SystemExit('Build failures: ' + json.dumps(failures))
    smoke()
    (DIST / 'registry.json').write_text(json.dumps({'schema_version': 1, 'records': records}, indent=2) + '\n')
    # Prepare an exact-bottle nb install. Only kegs made by this run are removed.
    for record in records:
        name = record['token']; digest = record['resolved']['assets']['macos-x86_64']['sha256']
        shutil.copyfile(DIST / f'{name}-{RECIPES[name]["version"]}.monterey.bottle.tar.gz',
                        Path('/opt/nanobrew/cache/blobs') / digest)
        shutil.rmtree(keg(name))


if __name__ == '__main__':
    main()
