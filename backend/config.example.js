module.exports = {
  server: process.env.DB_SERVER || '127.0.0.1',
  database: process.env.DB_NAME || 'ERP_SOLUTIONtst',
  user: process.env.DB_USER || 'sa',
  password: process.env.DB_PASSWORD || '',
  port: parseInt(process.env.DB_PORT || '1433', 10),
  pool: {
    max: 15,
    min: 2,
    idleTimeoutMillis: 30000,
  },
  options: {
    encrypt: false,
    trustServerCertificate: true,
    requestTimeout: 60000,
    connectTimeout: 30000,
  },
};
