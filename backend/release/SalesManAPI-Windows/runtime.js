const path = require('path');
const fs = require('fs');

function getAppRoot() {
  return process.pkg ? path.dirname(process.execPath) : path.resolve(__dirname);
}

function loadConfig() {
  require('dotenv').config({ path: path.join(getAppRoot(), '.env') });

  const externalConfig = path.join(getAppRoot(), 'config.js');
  if (fs.existsSync(externalConfig)) {
    delete require.cache[require.resolve(externalConfig)];
    return require(externalConfig);
  }

  return require('./config');
}

module.exports = {
  getAppRoot,
  loadConfig,
};
