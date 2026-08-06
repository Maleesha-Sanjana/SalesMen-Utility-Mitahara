module.exports = {
  // Database Configuration
  server: 'localhost', // Local SQL Server
  database: 'ERP_SOLUTIONtst', // ERP Solution database
  user: 'sa',
  password: 'Corei7@2022!',
  port: 1433,
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
  }
};
