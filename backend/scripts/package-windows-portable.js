const fs = require('fs');
const path = require('path');
const https = require('https');
const { execSync } = require('child_process');

const NODE_VERSION = '18.20.8';
const NODE_ZIP = `node-v${NODE_VERSION}-win-x64.zip`;
const NODE_URL = `https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ZIP}`;

const backendRoot = path.resolve(__dirname, '..');
const releaseRoot = path.join(backendRoot, 'release');
const packageRoot = path.join(releaseRoot, 'SalesManAPI-Windows');
const deployDir = path.join(backendRoot, 'deploy');
const cacheDir = path.join(backendRoot, '.cache');
const zipPath = path.join(releaseRoot, 'SalesManAPI-Windows.zip');

function copyFile(source, destination) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
}

function copyDirectory(source, destination) {
  if (!fs.existsSync(source)) return;
  fs.mkdirSync(destination, { recursive: true });
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const from = path.join(source, entry.name);
    const to = path.join(destination, entry.name);
    if (entry.isDirectory()) {
      copyDirectory(from, to);
    } else {
      copyFile(from, to);
    }
  }
}

function downloadFile(url, destination) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(destination);
    https
      .get(url, (response) => {
        if (
          response.statusCode &&
          response.statusCode >= 300 &&
          response.statusCode < 400 &&
          response.headers.location
        ) {
          file.close();
          fs.unlinkSync(destination);
          downloadFile(response.headers.location, destination).then(resolve).catch(reject);
          return;
        }

        if (response.statusCode !== 200) {
          reject(new Error(`Download failed (${response.statusCode}): ${url}`));
          return;
        }

        response.pipe(file);
        file.on('finish', () => file.close(resolve));
      })
      .on('error', (error) => {
        fs.unlink(destination, () => reject(error));
      });
  });
}

function run(command, cwd) {
  execSync(command, { cwd, stdio: 'inherit' });
}

async function main() {
  console.log('📦 Building Windows portable package from Mac...');
  console.log('   (This is not a single .exe, but works without a Windows build PC.)');
  console.log('');

  fs.mkdirSync(cacheDir, { recursive: true });
  fs.mkdirSync(releaseRoot, { recursive: true });

  if (fs.existsSync(packageRoot)) {
    fs.rmSync(packageRoot, { recursive: true, force: true });
  }
  fs.mkdirSync(packageRoot, { recursive: true });

  const runtimeFiles = [
    'server.js',
    'runtime.js',
    'package.json',
    'package-lock.json',
  ];

  for (const file of runtimeFiles) {
    copyFile(path.join(backendRoot, file), path.join(packageRoot, file));
  }

  copyDirectory(path.join(backendRoot, 'utils'), path.join(packageRoot, 'utils'));

  copyFile(path.join(backendRoot, 'config.js'), path.join(packageRoot, 'config.js'));
  copyFile(path.join(backendRoot, '.env.example'), path.join(packageRoot, '.env.example'));

  for (const file of ['open-firewall.ps1', 'install-service.ps1', 'DEPLOY.txt']) {
    copyFile(path.join(deployDir, file), path.join(packageRoot, file));
  }

  console.log('📥 Installing production npm dependencies...');
  run('npm ci --omit=dev', packageRoot);

  const zipCachePath = path.join(cacheDir, NODE_ZIP);
  if (!fs.existsSync(zipCachePath)) {
    console.log(`📥 Downloading Node.js ${NODE_VERSION} for Windows...`);
    await downloadFile(NODE_URL, zipCachePath);
  } else {
    console.log(`♻️  Using cached ${NODE_ZIP}`);
  }

  console.log('📂 Extracting portable Node.js for Windows...');
  fs.mkdirSync(path.join(packageRoot, 'node'), { recursive: true });
  run(`unzip -oq "${zipCachePath}" -d "${path.join(packageRoot, 'node')}"`, backendRoot);

  const extractedNodeDir = fs
    .readdirSync(path.join(packageRoot, 'node'))
    .find((name) => name.startsWith('node-v'));
  if (!extractedNodeDir) {
    throw new Error('Failed to extract Windows Node.js archive');
  }

  fs.renameSync(
    path.join(packageRoot, 'node', extractedNodeDir),
    path.join(packageRoot, 'node', 'runtime'),
  );

  const startBat = `@echo off
setlocal
cd /d "%~dp0"

echo Starting Sales Man Utility API...
echo Test URL: http://123.231.62.96:3000/api/health
echo.

".\\node\\runtime\\node.exe" server.js
pause
`;
  fs.writeFileSync(path.join(packageRoot, 'START-API.bat'), startBat, 'utf8');

  const readme = `Sales Man Utility - Windows Portable Package
==========================================

Built on Mac for Windows deployment.

1. Copy this entire folder to your Windows server
   Example: C:\\SalesManAPI\\

2. Copy .env.example to .env and set database password:
   copy .env.example .env
   notepad .env

3. Open firewall (PowerShell as Admin):
   powershell -ExecutionPolicy Bypass -File open-firewall.ps1

4. Double-click START-API.bat

No separate Node.js install is required on Windows.
This package includes portable Node.js for Windows.

For a single salesman-api.exe file, build on Windows or use GitHub Actions.
`;
  fs.writeFileSync(path.join(packageRoot, 'README.txt'), readme, 'utf8');

  if (fs.existsSync(zipPath)) {
    fs.unlinkSync(zipPath);
  }

  console.log('🗜️  Creating zip archive...');
  run(`cd "${releaseRoot}" && zip -rq "SalesManAPI-Windows.zip" "SalesManAPI-Windows"`, backendRoot);

  console.log('');
  console.log('✅ Windows package ready:');
  console.log(`   Folder: ${packageRoot}`);
  console.log(`   Zip:    ${zipPath}`);
  console.log('');
  console.log('Copy the zip to Windows, unzip, and run START-API.bat');
}

main().catch((error) => {
  console.error('❌ Failed to build Windows package:', error.message);
  process.exit(1);
});
