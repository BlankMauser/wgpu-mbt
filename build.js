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

// Builds wgpu-native from the pinned deps/wgpu-native submodule (cargo
// build --release, once) into a release-shaped tree under the cache, laid out
// like an upstream release zip, so the rest of the build is unchanged.
// Identity: the submodule must sit exactly at the pinned commit, unmodified.
function ensureSourceArtifact(asset) {
  const baseDir = path.join(
    cacheRoot(),
    'wgpu-native',
    SUPPORTED_RELEASE.tag,
    asset.archive.replace(/\.zip$/u, ''),
  );
  const tagPath = path.join(baseDir, 'wgpu-native-meta', 'wgpu-native-git-tag');
  const revPath = path.join(baseDir, 'wgpu-native-meta', 'wgpu-native-source-rev');
  if (
    fs.existsSync(path.join(baseDir, asset.staticLibRel)) &&
    fs.existsSync(tagPath) &&
    fs.readFileSync(tagPath, 'utf8').trim() === SUPPORTED_RELEASE.tag &&
    fs.existsSync(revPath) &&
    fs.readFileSync(revPath, 'utf8').trim() === SUPPORTED_RELEASE.rev
  ) {
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
  const dirty = git(src, ['status', '--porcelain', '--untracked-files=no', '--ignore-submodules=none']);
  if (dirty.length !== 0) {
    throw new Error(`${SUPPORTED_RELEASE.submodule} has local changes; refusing to cache them as ${SUPPORTED_RELEASE.tag}:\n${dirty}`);
  }
  // bindgen reads the C headers from wgpu-native's own submodule.
  const headers = path.join(src, 'ffi', 'webgpu-headers', 'webgpu.h');
  if (!fs.existsSync(headers)) {
    git(src, ['submodule', 'update', '--init', 'ffi/webgpu-headers']);
  }

  // A cargo target dir reused across builds: CARGO_TARGET_DIR if set.
  const targetDir = process.env.CARGO_TARGET_DIR && process.env.CARGO_TARGET_DIR.length !== 0
    ? path.resolve(process.env.CARGO_TARGET_DIR)
    : path.join(cacheRoot(), 'wgpu-native-src', 'target');
  ensureDir(targetDir);
  process.stderr.write(
    `wgpu_mbt: building wgpu-native ${SUPPORTED_RELEASE.tag} from source (cargo build --release, once) into ${targetDir}\n`,
  );
  // cargo's output goes to stderr: stdout carries the JSON moon reads.
  const cargo = spawnSync(
    'cargo',
    ['build', '--release', '--locked', '--manifest-path', path.join(src, 'Cargo.toml'), '-p', 'wgpu-native'],
    { stdio: ['ignore', 2, 2], env: { ...process.env, CARGO_TARGET_DIR: targetDir } },
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
    ensureDir(path.join(tmp, 'wgpu-native-meta'));
    fs.copyFileSync(
      path.join(src, 'ffi', 'webgpu-headers', 'webgpu.yml'),
      path.join(tmp, 'wgpu-native-meta', 'webgpu.yml'),
    );
    fs.writeFileSync(path.join(tmp, 'wgpu-native-meta', 'wgpu-native-git-tag'), `${SUPPORTED_RELEASE.tag}\n`);
    fs.writeFileSync(path.join(tmp, 'wgpu-native-meta', 'wgpu-native-source-rev'), `${SUPPORTED_RELEASE.rev}\n`);
    fs.rmSync(baseDir, { recursive: true, force: true });
    fs.renameSync(tmp, baseDir);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  return baseDir;
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
