module.exports = {
  server: process.env.DB_SERVER || '123.231.62.96',
  database: process.env.DB_NAME || 'ERP_SOLUTIONtst',
  user: process.env.DB_USER || 'sa',
  password: process.env.DB_PASSWORD || 'Corei7@2022!',
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
