const path = require('path');
const fs = require('fs');

function getAppRoot() {
  return process.pkg ? path.dirname(process.execPath) : path.resolve(__dirname);
}

function loadConfig() {
  const envPath = path.join(getAppRoot(), '.env');
  require('dotenv').config({ path: envPath });

  const configPath = path.join(getAppRoot(), 'config.js');
  if (fs.existsSync(configPath)) {
    delete require.cache[require.resolve(configPath)];
    return require(configPath);
  }

  delete require.cache[require.resolve('./config')];
  return require('./config');
}

module.exports = {
  getAppRoot,
  loadConfig,
};
