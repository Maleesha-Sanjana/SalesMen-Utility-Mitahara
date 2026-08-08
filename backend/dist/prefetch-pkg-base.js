const fs = require('fs');
const path = require('path');
const https = require('https');

const PKG_TAG = 'v3.6';
const NODE_VERSION = '18.20.8';
const PLATFORM = 'win-x64';
const ASSET_NAME = `node-v${NODE_VERSION}-${PLATFORM}`;
const CACHE_NAME = `fetched-v${NODE_VERSION}-${PLATFORM}`;
const DOWNLOAD_URL = `https://github.com/yao-pkg/pkg-fetch/releases/download/v3.5/${ASSET_NAME}`;

function getCacheRoot() {
  if (process.env.PKG_CACHE_PATH) {
    return process.env.PKG_CACHE_PATH;
  }
  const home = process.env.USERPROFILE || process.env.HOME || '';
  return path.join(home, '.pkg-cache');
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
          fs.unlink(destination, () => {
            downloadFile(response.headers.location, destination).then(resolve).catch(reject);
          });
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

async function main() {
  const cacheDir = path.join(getCacheRoot(), PKG_TAG);
  const cacheFile = path.join(cacheDir, CACHE_NAME);

  fs.mkdirSync(cacheDir, { recursive: true });

  if (fs.existsSync(cacheFile)) {
    console.log(`Using cached pkg base binary: ${cacheFile}`);
    return;
  }

  console.log(`Downloading ${ASSET_NAME} for pkg...`);
  console.log(`URL: ${DOWNLOAD_URL}`);

  const tempFile = `${cacheFile}.downloading`;
  await downloadFile(DOWNLOAD_URL, tempFile);
  fs.renameSync(tempFile, cacheFile);

  console.log(`Saved pkg base binary: ${cacheFile}`);
}

main().catch((error) => {
  console.error(`Failed to prefetch pkg base binary: ${error.message}`);
  process.exit(1);
});
