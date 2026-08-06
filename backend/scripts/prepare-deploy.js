const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const backendRoot = path.resolve(__dirname, '..');
const distDir = path.join(backendRoot, 'dist');
const deployDir = path.join(backendRoot, 'deploy');

function copyFile(source, destination) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
}

function copyDirectory(source, destination) {
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

console.log('📁 Preparing deployment package...');
if (fs.existsSync(distDir)) {
  fs.rmSync(distDir, { recursive: true, force: true });
}
fs.mkdirSync(distDir, { recursive: true });

const runtimeFiles = [
  'server.js',
  'runtime.js',
  'package.json',
  'package-lock.json',
];

for (const file of runtimeFiles) {
  copyFile(path.join(backendRoot, file), path.join(distDir, file));
}

copyDirectory(path.join(backendRoot, 'utils'), path.join(distDir, 'utils'));

copyFile(path.join(backendRoot, 'config.js'), path.join(distDir, 'config.js'));
copyFile(path.join(backendRoot, '.env.example'), path.join(distDir, '.env.example'));
copyFile(
  path.join(backendRoot, 'scripts', 'prefetch-pkg-base.js'),
  path.join(distDir, 'prefetch-pkg-base.js'),
);

const deployFiles = [
  'start-api.bat',
  'start-with-node.bat',
  'build-exe-on-windows.bat',
  'open-firewall.ps1',
  'install-service.ps1',
  'DEPLOY.txt',
];

for (const file of deployFiles) {
  copyFile(path.join(deployDir, file), path.join(distDir, file));
}

console.log('📥 Installing production node_modules in dist...');
execSync('npm ci --omit=dev', {
  cwd: distDir,
  stdio: 'inherit',
});

console.log('');
console.log('✅ Deployment package ready in backend/dist/');
console.log('');
console.log('Next on Windows server (Node 22 LTS required for .exe):');
console.log('  1. Copy backend/dist/ to D:\\Jazz\\Mobile Backend\\');
console.log('  2. copy .env.example .env');
console.log('  3. build-exe-on-windows.bat');
console.log('  4. start-api.bat');
