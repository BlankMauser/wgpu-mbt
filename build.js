const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { SUPPORTED_RELEASE, releaseAssetFor } = require('./scripts/wgpu_native_release');

const MODULE_NAME = 'Milky2018/wgpu_mbt';
const LINK_MODE = (process.env.MBT_WGPU_LINK_MODE || 'static').trim().toLowerCase();
const SANITIZE_MODE = (process.env.MBT_WGPU_NATIVE_SANITIZE || '').trim().toLowerCase();

function pkg(pathSuffix) {
  return pathSuffix.length === 0 ? MODULE_NAME : `${MODULE_NAME}/${pathSuffix}`;
}

function releaseAsset() {
  return releaseAssetFor({
    platform: os.platform(),
    arch: os.arch(),
    linkMode: 'static',
  });
}

function cacheRoot() {
  const override = process.env.MBT_WGPU_NATIVE_CACHE_DIR;
  if (override && override.length !== 0) {
    return override;
  }
  if (os.platform() === 'win32') {
    return path.join(
      process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'),
      'wgpu_mbt',
      'cache',
    );
  }
  if (os.platform() === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Caches', 'wgpu_mbt');
  }
  return path.join(os.homedir(), '.cache', 'wgpu_mbt');
}

function extractedRootOverride() {
  const override = process.env.MBT_WGPU_NATIVE_ROOT;
  if (!override || override.length === 0) {
    return '';
  }
  return path.resolve(override);
}

function quoteArg(value) {
  if (!value.includes(' ') && !value.includes('\t')) {
    return value;
  }
  return `"${value.replace(/"/g, '\\"')}"`;
}

function escapeDefineString(value) {
  return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function sanitizerCompileFlags() {
  if (SANITIZE_MODE.length === 0) {
    return [];
  }
  if (SANITIZE_MODE !== 'address') {
    throw new Error(`unsupported MBT_WGPU_NATIVE_SANITIZE: ${SANITIZE_MODE}`);
  }
  return ['-fsanitize=address', '-fno-omit-frame-pointer'];
}

function sanitizerLinkFlags() {
  if (SANITIZE_MODE.length === 0) {
    return [];
  }
  if (SANITIZE_MODE !== 'address') {
    throw new Error(`unsupported MBT_WGPU_NATIVE_SANITIZE: ${SANITIZE_MODE}`);
  }
  return ['-fsanitize=address'];
}

function stubCcFlags({ staticLink, asset }) {
  const flags = [
    `-DMBT_WGPU_STATIC_LINK=${staticLink ? '1' : '0'}`,
    `-DMBT_WGPU_SUPPORTED_TAG=\\\"${escapeDefineString(SUPPORTED_RELEASE.tag)}\\\"`,
    `-DMBT_WGPU_SUPPORTED_REV=\\\"${escapeDefineString(SUPPORTED_RELEASE.rev)}\\\"`,
  ];
  if (os.platform() === 'win32') {
    flags.push('/std:c11', '/experimental:c11atomics');
  }
  if (staticLink && asset) {
    flags.push(`-DMBT_WGPU_STATIC_HAS_PIPELINE_ASYNC=${asset.pipelineAsync ? '1' : '0'}`);
    flags.push(`-DMBT_WGPU_STATIC_HAS_COMPILATION_INFO=${asset.compilationInfo ? '1' : '0'}`);
    flags.push(`-DMBT_WGPU_STATIC_ARCHIVE=\\\"${escapeDefineString(asset.archive)}\\\"`);
  } else {
    flags.push('-DMBT_WGPU_STATIC_HAS_PIPELINE_ASYNC=0');
    flags.push('-DMBT_WGPU_STATIC_HAS_COMPILATION_INFO=0');
    flags.push('-DMBT_WGPU_STATIC_ARCHIVE=\\\"\\\"');
  }
  flags.push(...sanitizerCompileFlags());
  return flags.join(' ');
}

function runChecked(command, args) {
  const child = spawnSync(command, args, {
    stdio: 'inherit',
  });
  if (child.status !== 0) {
    throw new Error(`${command} exited with status ${child.status}`);
  }
}

function sha256File(filePath) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(filePath));
  return hash.digest('hex');
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function validateExtractedReleaseRoot(rootDir, libRel) {
  const libPath = path.join(rootDir, libRel);
  const tagPath = path.join(rootDir, 'wgpu-native-meta', 'wgpu-native-git-tag');
  if (!fs.existsSync(libPath)) {
    throw new Error(
      `MBT_WGPU_NATIVE_ROOT is missing ${libRel}: ${libPath}`,
    );
  }
  if (!fs.existsSync(tagPath)) {
    throw new Error(
      `MBT_WGPU_NATIVE_ROOT is missing release metadata: ${tagPath}`,
    );
  }
  const tag = fs.readFileSync(tagPath, 'utf8').trim();
  if (tag !== SUPPORTED_RELEASE.tag) {
    throw new Error(
      `MBT_WGPU_NATIVE_ROOT tag mismatch: expected ${SUPPORTED_RELEASE.tag}, got ${tag}`,
    );
  }
  return rootDir;
}

function downloadFile(url, outPath) {
  const headers = [];
  const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN || '';
  if (token.length !== 0) {
    headers.push('Authorization: Bearer ' + token);
  }
  headers.push('Accept: application/octet-stream');
  const args = ['-L', '--fail', '--silent', '--show-error', '-o', outPath];
  for (const header of headers) {
    args.push('-H', header);
  }
  args.push(url);
  runChecked('curl', args);
}

function extractZip(zipPath, outDir) {
  ensureDir(outDir);
  if (os.platform() === 'win32') {
    runChecked('powershell', [
      '-NoProfile',
      '-Command',
      `Expand-Archive -Path '${zipPath.replace(/'/g, "''")}' -DestinationPath '${outDir.replace(/'/g, "''")}' -Force`,
    ]);
    return;
  }
  runChecked('unzip', ['-q', '-o', zipPath, '-d', outDir]);
}

function git(dir, args) {
  const r = spawnSync('git', ['-C', dir, ...args], { encoding: 'utf8' });
  if (r.status !== 0) {
    throw new Error(`git -C ${dir} ${args.join(' ')} failed: ${(r.stderr || '').trim()}`);
  }
  return r.stdout.trim();
}

// Blocking sleep without a busy loop (build.js is synchronous).
function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// An exclusive lock file (two worktrees sharing one cache may build at once).
// The holder's pid is written into it; a lock whose holder is gone is broken.
function withLock(lockPath, f) {
  ensureDir(path.dirname(lockPath));
  let warned = false;
  for (;;) {
    try {
      const fd = fs.openSync(lockPath, 'wx');
      fs.writeSync(fd, `${process.pid}\n`);
      fs.closeSync(fd);
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') {
        throw e;
      }
      let holder = NaN;
      try {
        holder = parseInt(fs.readFileSync(lockPath, 'utf8'), 10);
      } catch (_) {
        // Being written or just removed: retry.
      }
      let alive = true;
      if (Number.isInteger(holder) && holder > 0) {
        try {
          process.kill(holder, 0);
        } catch (err) {
          alive = err.code === 'EPERM';
        }
      }
      if (!alive) {
        fs.rmSync(lockPath, { force: true });
        continue;
      }
      if (!warned) {
        process.stderr.write(`wgpu_mbt: waiting for ${lockPath} (held by pid ${Number.isInteger(holder) ? holder : "?"})\n`);
        warned = true;
      }
      sleepMs(500);
    }
  }
  try {
    return f();
  } finally {
    fs.rmSync(lockPath, { force: true });
  }
}

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, ...opts });
  if (r.error || r.status !== 0) {
    throw new Error(
      `${cmd} ${args.join(' ')} failed (${r.error ? r.error.message : `status ${r.status}`}): ${(r.stderr || '').trim()}`,
    );
  }
  return r.stdout;
}

// What else decides the binary besides the source: toolchain and build env.
// Recorded next to the artifact, and compared (with a warning) on cache hits.
function buildEnvironment(env) {
  const rustc = env.RUSTC && env.RUSTC.length !== 0 ? env.RUSTC : 'rustc';
  const record = { rustc: run(rustc, ['-vV'], { env }).trim(), env: {} };
  for (const key of Object.keys(env).sort()) {
    if (
      key === 'RUSTFLAGS' ||
      key === 'CARGO_ENCODED_RUSTFLAGS' ||
      key === 'RUSTC' ||
      key === 'RUSTC_WRAPPER' ||
      key === 'CARGO_BUILD_TARGET' ||
      key.startsWith('CARGO_TARGET_') && key !== 'CARGO_TARGET_DIR' ||
      key.startsWith('CARGO_PROFILE_')
    ) {
      record.env[key] = env[key];
    }
  }
  return record;
}

// A `paths` override in any .cargo/config.toml above the cwd (or in
// ~/.cargo) would swap a pinned crate for a local tree while --locked and the
// clean-submodule check still pass. Refuse any non-workspace package that
// resolves to a path.
function refusePathSources(src, env) {
  const meta = JSON.parse(
    run('cargo', ['metadata', '--locked', '--format-version', '1', '--manifest-path', path.join(src, 'Cargo.toml')], {
      env,
    }),
  );
  const members = new Set(meta.workspace_members);
  const offenders = meta.packages
    .filter((p) => !members.has(p.id) && (p.source === null || String(p.source).startsWith('path+')))
    .map((p) => `${p.name} ${p.version} (${p.manifest_path})`);
  if (offenders.length !== 0) {
    throw new Error(
      `refusing to build ${SUPPORTED_RELEASE.tag}: dependencies resolve to local paths (a cargo \`paths\` override or [patch]?):\n  ${offenders.join('\n  ')}`,
    );
  }
}

// Builds wgpu-native from the pinned deps/wgpu-native submodule (cargo
// build --release, once) into a release-shaped tree under the cache, laid out
// like an upstream release zip, so the rest of the build is unchanged.
// Identity: the submodule must sit exactly at the pinned commit, unmodified
// (tracked or untracked), and every dependency must come from the lockfile's
// registry sources. The toolchain and build env are recorded alongside.
function ensureSourceArtifact(asset) {
  const baseDir = path.join(
    cacheRoot(),
    'wgpu-native',
    SUPPORTED_RELEASE.tag,
    asset.archive.replace(/\.zip$/u, ''),
  );
  const metaDir = path.join(baseDir, 'wgpu-native-meta');
  const cached = () =>
    fs.existsSync(path.join(baseDir, asset.staticLibRel)) &&
    fs.existsSync(path.join(metaDir, 'wgpu-native-git-tag')) &&
    fs.readFileSync(path.join(metaDir, 'wgpu-native-git-tag'), 'utf8').trim() === SUPPORTED_RELEASE.tag &&
    fs.existsSync(path.join(metaDir, 'wgpu-native-source-rev')) &&
    fs.readFileSync(path.join(metaDir, 'wgpu-native-source-rev'), 'utf8').trim() === SUPPORTED_RELEASE.rev;

  return withLock(`${path.dirname(baseDir)}.lock`, () => {
    if (cached()) {
      warnOnEnvironmentDrift(metaDir);
      return baseDir;
    }
    const src = path.join(__dirname, SUPPORTED_RELEASE.submodule);
    if (!fs.existsSync(path.join(src, 'Cargo.toml'))) {
      throw new Error(
        `wgpu-native source missing at ${src}: run \`git submodule update --init --recursive\` in the wgpu_mbt checkout`,
      );
    }
    const head = git(src, ['rev-parse', 'HEAD']);
    if (head !== SUPPORTED_RELEASE.rev) {
      throw new Error(
        `${SUPPORTED_RELEASE.submodule} is at ${head}, expected the pinned ${SUPPORTED_RELEASE.rev} (git submodule update)`,
      );
    }
    // bindgen reads the C headers from wgpu-native's own submodule.
    const headers = path.join(src, 'ffi', 'webgpu-headers', 'webgpu.h');
    if (!fs.existsSync(headers)) {
      git(src, ['submodule', 'update', '--init', 'ffi/webgpu-headers']);
    }
    const dirty = git(src, ['status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none']);
    if (dirty.length !== 0) {
      throw new Error(
        `${SUPPORTED_RELEASE.submodule} has local changes or untracked files; refusing to cache them as ${SUPPORTED_RELEASE.tag}:\n${dirty}`,
      );
    }

    // A cargo target dir reused across builds: CARGO_TARGET_DIR if set, else
    // next to the source in this checkout (gitignored target/), never inside
    // the cache dir, which holds only the finished tree.
    const targetDir =
      process.env.CARGO_TARGET_DIR && process.env.CARGO_TARGET_DIR.length !== 0
        ? path.resolve(process.env.CARGO_TARGET_DIR)
        : path.join(__dirname, 'target', 'wgpu-native');
    ensureDir(targetDir);
    const env = { ...process.env, CARGO_TARGET_DIR: targetDir };
    refusePathSources(src, env);
    const buildEnv = buildEnvironment(env);
    process.stderr.write(
      `wgpu_mbt: building wgpu-native ${SUPPORTED_RELEASE.tag} from source (cargo build --release, once) into ${targetDir}\n`,
    );
    // cargo's output goes to stderr: stdout carries the JSON moon reads.
    const cargo = spawnSync(
      'cargo',
      ['build', '--release', '--locked', '--manifest-path', path.join(src, 'Cargo.toml'), '-p', 'wgpu-native'],
      { stdio: ['ignore', 2, 2], env },
    );
    if (cargo.error || cargo.status !== 0) {
      throw new Error(
        `cargo build of wgpu-native failed (${cargo.error ? cargo.error.message : `status ${cargo.status}`}); Rust (cargo) is required to build this fork`,
      );
    }
    const built = path.join(targetDir, 'release');
    ensureDir(path.dirname(baseDir));
    const tmp = fs.mkdtempSync(path.join(path.dirname(baseDir), '.wgpu-native-src-'));
    try {
      for (const rel of [asset.staticLibRel, asset.dynamicLibRel]) {
        ensureDir(path.join(tmp, path.dirname(rel)));
        fs.copyFileSync(path.join(built, path.basename(rel)), path.join(tmp, rel));
      }
      ensureDir(path.join(tmp, 'include', 'webgpu'));
      fs.copyFileSync(headers, path.join(tmp, 'include', 'webgpu', 'webgpu.h'));
      fs.copyFileSync(path.join(src, 'ffi', 'wgpu.h'), path.join(tmp, 'include', 'webgpu', 'wgpu.h'));
      const tmpMeta = path.join(tmp, 'wgpu-native-meta');
      ensureDir(tmpMeta);
      fs.copyFileSync(path.join(src, 'ffi', 'webgpu-headers', 'webgpu.yml'), path.join(tmpMeta, 'webgpu.yml'));
      fs.writeFileSync(path.join(tmpMeta, 'wgpu-native-git-tag'), `${SUPPORTED_RELEASE.tag}\n`);
      fs.writeFileSync(path.join(tmpMeta, 'wgpu-native-source-rev'), `${SUPPORTED_RELEASE.rev}\n`);
      fs.writeFileSync(path.join(tmpMeta, 'build-environment.json'), `${JSON.stringify(buildEnv, null, 2)}\n`);
      fs.rmSync(baseDir, { recursive: true, force: true });
      fs.renameSync(tmp, baseDir);
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
    return baseDir;
  });
}

// The cache key is (label, source commit). A cached tree built with another
// toolchain or build env is still used, with a warning.
function warnOnEnvironmentDrift(metaDir) {
  const recorded = path.join(metaDir, 'build-environment.json');
  if (!fs.existsSync(recorded)) {
    process.stderr.write(`wgpu_mbt: cached wgpu-native has no recorded build environment (${metaDir})\n`);
    return;
  }
  let now;
  try {
    now = buildEnvironment({ ...process.env });
  } catch (_) {
    return; // No rustc here: nothing to compare (and nothing to rebuild with).
  }
  const was = JSON.parse(fs.readFileSync(recorded, 'utf8'));
  if (JSON.stringify(was) !== JSON.stringify(now)) {
    process.stderr.write(
      `wgpu_mbt: cached wgpu-native ${SUPPORTED_RELEASE.tag} was built with a different toolchain or build env; using it anyway (delete ${path.dirname(metaDir)} to rebuild).\n  was: ${JSON.stringify(was)}\n  now: ${JSON.stringify(now)}\n`,
    );
  }
}

function ensureStaticArtifact(asset) {
  const preseededRoot = extractedRootOverride();
  if (preseededRoot.length !== 0) {
    return validateExtractedReleaseRoot(preseededRoot, asset.staticLibRel);
  }
  if (SUPPORTED_RELEASE.fromSource) {
    return ensureSourceArtifact(asset);
  }

  const baseDir = path.join(
    cacheRoot(),
    'wgpu-native',
    SUPPORTED_RELEASE.tag,
    asset.archive.replace(/\.zip$/u, ''),
  );
  const staticLibPath = path.join(baseDir, asset.staticLibRel);
  const tagPath = path.join(baseDir, 'wgpu-native-meta', 'wgpu-native-git-tag');
  if (fs.existsSync(staticLibPath) && fs.existsSync(tagPath)) {
    const tag = fs.readFileSync(tagPath, 'utf8').trim();
    if (tag === SUPPORTED_RELEASE.tag) {
      return baseDir;
    }
  }

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wgpu-mbt-static-'));
  const zipPath = path.join(tmpDir, asset.archive);
  const extractDir = path.join(tmpDir, 'extract');
  const assetUrl = `https://github.com/${SUPPORTED_RELEASE.repo}/releases/download/${SUPPORTED_RELEASE.tag}/${asset.archive}`;

  try {
    downloadFile(assetUrl, zipPath);
    const actualSha = sha256File(zipPath);
    if (actualSha !== asset.sha256) {
      throw new Error(
        `sha256 mismatch for ${asset.archive}: expected ${asset.sha256}, got ${actualSha}`,
      );
    }
    extractZip(zipPath, extractDir);
    const extractedStaticLib = path.join(extractDir, asset.staticLibRel);
    const extractedTagPath = path.join(extractDir, 'wgpu-native-meta', 'wgpu-native-git-tag');
    if (!fs.existsSync(extractedStaticLib)) {
      throw new Error(`missing static library after extraction: ${extractedStaticLib}`);
    }
    if (!fs.existsSync(extractedTagPath)) {
      throw new Error(`missing release metadata after extraction: ${extractedTagPath}`);
    }
    const extractedTag = fs.readFileSync(extractedTagPath, 'utf8').trim();
    if (extractedTag !== SUPPORTED_RELEASE.tag) {
      throw new Error(
        `unexpected release metadata tag: expected ${SUPPORTED_RELEASE.tag}, got ${extractedTag}`,
      );
    }
    fs.rmSync(baseDir, { recursive: true, force: true });
    ensureDir(path.dirname(baseDir));
    fs.cpSync(extractDir, baseDir, { recursive: true });
    return baseDir;
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

function staticLinkFlags(baseDir, asset) {
  const staticLibPath = path.join(baseDir, asset.staticLibRel);
  const normalizedStaticLibPath =
    os.platform() === 'win32' ? staticLibPath.replace(/\\/g, '/') : staticLibPath;
  const flags = [quoteArg(normalizedStaticLibPath), ...asset.linkFlags];
  if (os.platform() === 'win32') {
    const explicitVulkanImportLib = process.env.MBT_WGPU_VULKAN_LIB || '';
    const sdkRoot = process.env.VULKAN_SDK || '';
    const sdkVersion = process.env.VULKAN_VERSION || '';
    const candidates = [];
    if (explicitVulkanImportLib.length !== 0) {
      candidates.push(explicitVulkanImportLib);
    }
    if (sdkRoot.length !== 0) {
      if (sdkVersion.length !== 0) {
        candidates.push(path.join(sdkRoot, sdkVersion, 'Lib', 'vulkan-1.lib'));
      }
      candidates.push(path.join(sdkRoot, 'Lib', 'vulkan-1.lib'));
    }
    let vulkanImportLib = null;
    for (const candidate of candidates) {
      if (fs.existsSync(candidate)) {
        vulkanImportLib = candidate.replace(/\\/g, '/');
        break;
      }
    }
    flags.push(vulkanImportLib ? quoteArg(vulkanImportLib) : '-lvulkan-1');
  }
  flags.push(...sanitizerLinkFlags());
  return flags.join(' ');
}

function main() {
  if (LINK_MODE !== 'dynamic' && LINK_MODE !== 'static') {
    throw new Error(`unsupported MBT_WGPU_LINK_MODE: ${LINK_MODE}`);
  }

  const asset = releaseAsset();
  const linkConfigs = [];
  if (LINK_MODE === 'static') {
    if (!asset) {
      throw new Error(
        `unsupported platform/arch for static wgpu-native: ${os.platform()}/${os.arch()}`,
      );
    }
    const baseDir = ensureStaticArtifact(asset);
    linkConfigs.push({
      package: pkg('c'),
      link_flags: staticLinkFlags(baseDir, asset),
    });
  } else if (SANITIZE_MODE.length !== 0) {
    linkConfigs.push({
      package: pkg('c'),
      link_flags: sanitizerLinkFlags().join(' '),
    });
  }

  console.log(
    JSON.stringify({
      vars: {
        WGPU_MBT_C_STUB_CC_FLAGS: stubCcFlags({
          staticLink: LINK_MODE === 'static',
          asset,
        }),
      },
      link_configs: linkConfigs,
    }),
  );
}

main();
