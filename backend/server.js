const express = require('express');
const cors = require('cors');
const compression = require('compression');
const sql = require('mssql');
const runtime = require('./runtime');
const config = runtime.loadConfig();
const http = require('http');
const WebSocket = require('ws');
const { Resend } = require('resend');
const { getNewDeviceLoginEmailHtml } = require('./utils/emailTemplate');
const resend = new Resend('re_PN6gqU1e_Kz4C2TzoFeZ52ZaUBnXvrNK7'); // Using provided API key

const errorLogger = require('./utils/errorLogger');

errorLogger.initialize();

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(compression());
app.use(cors());
app.use(express.json({ limit: '10mb' }));

// Database connection pool
let pool;

const DESIRED_INVOICE_PRODUCT_COLUMNS = [
  'ProductCode',
  'ProductName',
  'NameOnInvoice',
  'LongDescription',
  'SellingUnit',
  'Unit',
  'Margin',
  'PackSize',
  'ReOrderQty',
  'CostPrice',
  'UnitPrice',
  'WholeSalePrice',
  'BatchNo',
  'StockLoca',
  'Tax',
  'SerialNo',
  'WarrantyPeriod',
  'Phase',
  'PeriodDays',
  'AvgCostPrice',
  'RefCode',
  'ExpiryDate',
  'IsBatch',
  'IsExpiry',
  'IsSemi',
  'IsAuthority',
  'AvgDiscount',
  'AvgOther',
  'AvgVat',
  'AvgMasterCostPrice',
];

let invoiceProductSelectClauseCache = null;

async function getInvoiceProductSelectClause() {
  if (invoiceProductSelectClauseCache) {
    return invoiceProductSelectClauseCache;
  }
  if (!pool) {
    throw new Error('Database not connected');
  }

  const result = await pool.request().query(`
    SELECT COLUMN_NAME
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'inv_productmaster'
  `);
  const available = new Set(result.recordset.map((row) => row.COLUMN_NAME));
  const columns = DESIRED_INVOICE_PRODUCT_COLUMNS.filter((col) =>
    available.has(col),
  );

  if (columns.length === 0) {
    throw new Error('No matching columns found in inv_productmaster');
  }

  invoiceProductSelectClauseCache = columns.join(',\n  ');
  console.log(
    `📋 inv_productmaster query uses ${columns.length}/${DESIRED_INVOICE_PRODUCT_COLUMNS.length} columns`,
  );
  return invoiceProductSelectClauseCache;
}

const RESPONSE_CACHE_TTL_MS = 5 * 60 * 1000;
const responseCache = new Map();
const lastLocationUpdates = new Map();

function getCachedResponse(cacheKey) {
  const entry = responseCache.get(cacheKey);
  if (!entry) return null;
  if (Date.now() > entry.expiresAt) {
    responseCache.delete(cacheKey);
    return null;
  }
  return entry.data;
}

function setCachedResponse(cacheKey, data) {
  responseCache.set(cacheKey, {
    data,
    expiresAt: Date.now() + RESPONSE_CACHE_TTL_MS,
  });
}

function invalidateCustomerCaches() {
  for (const key of responseCache.keys()) {
    if (key.startsWith('customers:')) {
      responseCache.delete(key);
    }
  }
}

function isLocalCustomerCode(customerCode) {
  return (customerCode || '').toUpperCase().startsWith('LOCAL-');
}

function bindCustomerCodeInput(request, paramName, customerCode) {
  return request.input(
    paramName,
    sql.NVarChar(50),
    (customerCode || '').toString().trim().substring(0, 50),
  );
}

function shouldSkipLocationUpdate(userCode, latitude, longitude) {
  const last = lastLocationUpdates.get(userCode);
  if (!last) return false;

  const sameLocation =
    Math.abs(last.latitude - latitude) < 0.0001 &&
    Math.abs(last.longitude - longitude) < 0.0001;
  const recent = Date.now() - last.updatedAt < 45000;

  return sameLocation && recent;
}

function rememberLocationUpdate(userCode, latitude, longitude) {
  lastLocationUpdates.set(userCode, {
    latitude,
    longitude,
    updatedAt: Date.now(),
  });
}

function normalizeLocaCode(value) {
  const raw = (value || '01').toString().trim();
  if (!raw || raw.length > 5) {
    return '01';
  }
  return raw;
}

function normalizeCostCenter(value) {
  const raw = (value || '000001').toString().trim();
  if (!raw || raw.length > 10) {
    return '000001';
  }
  return raw;
}

async function ensureUserLocTable() {
  if (!pool) return false;

  await pool.request().query(`
    IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='gen_userLoc' AND xtype='U')
    CREATE TABLE gen_userLoc (
      id INT IDENTITY(1,1) PRIMARY KEY,
      userCode NVARCHAR(50) NOT NULL,
      userName NVARCHAR(100) NOT NULL,
      latitude FLOAT NOT NULL,
      longitude FLOAT NOT NULL,
      accuracy FLOAT NULL DEFAULT 0,
      speed FLOAT NULL DEFAULT 0,
      heading FLOAT NULL DEFAULT 0,
      address NVARCHAR(255) NULL,
      timestamp DATETIME2 NOT NULL DEFAULT GETDATE(),
      created_at DATETIME2 NOT NULL DEFAULT GETDATE(),
      updated_at DATETIME2 NOT NULL DEFAULT GETDATE(),
      isActive BIT NOT NULL DEFAULT 1,
      CONSTRAINT UQ_gen_userLoc_userCode UNIQUE (userCode)
    )
  `);

  return true;
}

async function ensureSalesmanPlaceCheckInTable() {
  if (!pool) return false;

  await pool.request().query(`
    IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='gen_salesmanPlaceCheckIn' AND xtype='U')
    CREATE TABLE gen_salesmanPlaceCheckIn (
      id INT IDENTITY(1,1) PRIMARY KEY,
      SalesmanCode NVARCHAR(15) NOT NULL,
      SalesmanName NVARCHAR(100) NULL,
      PlaceName NVARCHAR(100) NOT NULL,
      Latitude DECIMAL(10, 8) NOT NULL,
      Longitude DECIMAL(11, 8) NOT NULL,
      Accuracy FLOAT NULL DEFAULT 0,
      Remarks NVARCHAR(255) NULL,
      CheckedInAt DATETIME2 NOT NULL DEFAULT GETDATE(),
      Created_Date DATETIME2 NOT NULL DEFAULT GETDATE()
    );

    IF NOT EXISTS (
      SELECT 1 FROM sys.indexes
      WHERE name = 'IX_gen_salesmanPlaceCheckIn_SalesmanCode_CheckedInAt'
        AND object_id = OBJECT_ID('gen_salesmanPlaceCheckIn')
    )
    CREATE INDEX IX_gen_salesmanPlaceCheckIn_SalesmanCode_CheckedInAt
      ON gen_salesmanPlaceCheckIn (SalesmanCode, CheckedInAt DESC);
  `);

  return true;
}

async function ensureAssignedColumnInCustomer() {
  if (!pool) return false;

  try {
    await pool.request().query(`
      IF COL_LENGTH('dbo.gen_customer', 'Assigned') IS NULL
      BEGIN
          ALTER TABLE dbo.gen_customer
          ADD Assigned NVARCHAR(50) NULL;
      END
    `);
    console.log('✅ Checked/Added Assigned column to gen_customer');
  } catch (error) {
    console.error('❌ Error adding Assigned column:', error);
  }
  return true;
}

async function insertSalesmanPlaceCheckIn({
  salesmanCode,
  salesmanName,
  placeName,
  latitude,
  longitude,
  accuracy = 0,
  remarks = '',
  checkedInAt = new Date(),
}) {
  await ensureSalesmanPlaceCheckInTable();

  const result = await pool.request()
    .input('salesmanCode', sql.NVarChar(15), salesmanCode)
    .input('salesmanName', sql.NVarChar(100), salesmanName)
    .input('placeName', sql.NVarChar(100), placeName)
    .input('latitude', sql.Decimal(10, 8), latitude)
    .input('longitude', sql.Decimal(11, 8), longitude)
    .input('accuracy', sql.Float, accuracy || 0)
    .input('remarks', sql.NVarChar(255), remarks || '')
    .input('checkedInAt', sql.DateTime2, checkedInAt)
    .query(`
      INSERT INTO gen_salesmanPlaceCheckIn (
        SalesmanCode,
        SalesmanName,
        PlaceName,
        Latitude,
        Longitude,
        Accuracy,
        Remarks,
        CheckedInAt,
        Created_Date
      )
      OUTPUT INSERTED.id AS id, INSERTED.CheckedInAt AS checkedInAt
      VALUES (
        @salesmanCode,
        @salesmanName,
        @placeName,
        @latitude,
        @longitude,
        @accuracy,
        @remarks,
        @checkedInAt,
        GETDATE()
      )
    `);

  return result.recordset[0] || {};
}

async function upsertUserLiveLocation({
  userCode,
  userName,
  latitude,
  longitude,
  accuracy = 0,
  speed = 0,
  heading = 0,
  address = '',
  timestamp = new Date(),
}) {
  const parsedLatitude = Number(latitude);
  const parsedLongitude = Number(longitude);
  const cleanAddress = (address || '').toString().trim().substring(0, 255);
  const locationLabel =
    cleanAddress ||
    `${parsedLatitude.toFixed(6)},${parsedLongitude.toFixed(6)}`;
  const resolvedTimestamp =
    timestamp instanceof Date ? timestamp : new Date(timestamp);

  await ensureUserLocTable();
  await ensureAssignedColumnInCustomer();

  await pool.request()
    .input('userCode', sql.NVarChar, userCode)
    .input('userName', sql.NVarChar, userName)
    .input('latitude', sql.Float, parsedLatitude)
    .input('longitude', sql.Float, parsedLongitude)
    .input('accuracy', sql.Float, accuracy || 0)
    .input('speed', sql.Float, speed || 0)
    .input('heading', sql.Float, heading || 0)
    .input('address', sql.NVarChar(255), locationLabel)
    .input('timestamp', sql.DateTime2, resolvedTimestamp)
    .query(`
      MERGE gen_userLoc AS target
      USING (SELECT @userCode AS userCode) AS source
      ON target.userCode = source.userCode
      WHEN MATCHED THEN
        UPDATE SET 
          userName = @userName,
          latitude = @latitude,
          longitude = @longitude,
          accuracy = @accuracy,
          speed = @speed,
          heading = @heading,
          address = @address,
          timestamp = @timestamp,
          updated_at = GETDATE(),
          isActive = 1
      WHEN NOT MATCHED THEN
        INSERT (userCode, userName, latitude, longitude, accuracy, speed, heading, address, timestamp, isActive)
        VALUES (@userCode, @userName, @latitude, @longitude, @accuracy, @speed, @heading, @address, @timestamp, 1);
    `);

  rememberLocationUpdate(userCode, parsedLatitude, parsedLongitude);

  broadcastDataChange('location_update', {
    userCode,
    userName,
    latitude: parsedLatitude,
    longitude: parsedLongitude,
    accuracy: accuracy || 0,
    timestamp: resolvedTimestamp.toISOString(),
    status: 'Active',
  });
}

// WebSocket server
let wss;
const connectedClients = new Set();

// Initialize database connection
async function initializeDatabase() {
  let retries = 5;
  let delay = 2000; // Start with 2 seconds delay
  
  while (retries > 0) {
    try {
      console.log(`🔌 Attempting to connect to database (${6-retries}/5)...`);
      pool = await sql.connect(config);
      console.log('✅ Connected to SQL Server database');
      await ensureUserLocTable();
      console.log('✅ Location tracking table ready');
      await ensureAssignedColumnInCustomer();
      await ensureSalesmanPlaceCheckInTable();
      console.log('✅ Salesman place check-in table ready');
      
      // Ensure isLogged column exists in gen_salesman
      await pool.request().query(`
        IF NOT EXISTS (
          SELECT 1 FROM sys.columns
          WHERE object_id = OBJECT_ID('gen_salesman') AND name = 'isLogged'
        )
        ALTER TABLE gen_salesman ADD isLogged BIT NOT NULL CONSTRAINT DF_gen_salesman_isLogged DEFAULT 0;
      `);
      console.log('✅ Salesman isLogged column ready');
      
      return; // Success, exit the function
    } catch (err) {
      retries--;
      console.error(`❌ Database connection failed (${6-retries}/5):`, err.message);
      
      if (retries > 0) {
        console.log(`⏳ Retrying in ${delay/1000} seconds...`);
        await new Promise(resolve => setTimeout(resolve, delay));
        delay *= 1.5; // Exponential backoff
      } else {
        console.error('❌ Failed to connect to database after 5 attempts');
        console.log('⚠️  Server will continue running but API endpoints will fail without database connection');
        pool = null; // Set pool to null to indicate no database connection
      }
    }
  }
}

// Initialize database on startup
initializeDatabase();

// ==================== WEBSOCKET SERVER ====================

// Initialize WebSocket server
function initializeWebSocket(server) {
  wss = new WebSocket.Server({ 
    server,
    path: '/ws',
    perMessageDeflate: false
  });

  wss.on('connection', (ws, req) => {
    console.log('🔌 WebSocket client connected from:', req.socket.remoteAddress);
    connectedClients.add(ws);

    // Send connection status
    ws.send(JSON.stringify({
      type: 'connection_status',
      status: 'connected',
      timestamp: new Date().toISOString()
    }));

    // Handle client messages
    ws.on('message', (message) => {
      try {
        const data = JSON.parse(message);
        console.log('📨 WebSocket message received:', data.type);
        
        switch (data.type) {
          case 'ping':
            ws.send(JSON.stringify({
              type: 'pong',
              timestamp: new Date().toISOString()
            }));
            break;
          case 'subscribe':
            // Handle subscription to specific data types
            console.log('📝 Client subscribed to:', data.dataTypes);
            break;
          default:
            console.log('⚠️ Unknown WebSocket message type:', data.type);
        }
      } catch (error) {
        console.error('❌ Error processing WebSocket message:', error);
      }
    });

    // Handle client disconnect
    ws.on('close', () => {
      console.log('🔌 WebSocket client disconnected');
      connectedClients.delete(ws);
    });

    // Handle errors
    ws.on('error', (error) => {
      console.error('❌ WebSocket error:', error);
      connectedClients.delete(ws);
    });
  });

  console.log('✅ WebSocket server initialized');
}

// Broadcast data changes to all connected clients
function broadcastDataChange(dataType, data) {
  if (connectedClients.size === 0) return;

  const message = JSON.stringify({
    type: 'data_change',
    dataType: dataType,
    data: data,
    timestamp: new Date().toISOString()
  });

  console.log(`📡 Broadcasting ${dataType} change to ${connectedClients.size} clients`);
  
  connectedClients.forEach((client) => {
    if (client.readyState === WebSocket.OPEN) {
      client.send(message);
    } else {
      // Remove disconnected clients
      connectedClients.delete(client);
    }
  });
}

// Check for data changes endpoint
app.get('/api/sync/check-changes', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const { type } = req.query;
    
    let query;
    switch (type) {
      case 'departments':
        query = 'SELECT MAX(ModifiedDate) as lastModified FROM inv_department';
        break;
      case 'products':
        query = 'SELECT MAX(ModifiedDate) as lastModified FROM inv_productmaster';
        break;
      case 'suspend_orders':
        query = 'SELECT MAX(CreatedDate) as lastModified FROM inv_suspend';
        break;
      case 'orders':
        query = 'SELECT MAX(CreatedDate) as lastModified FROM inv_orders';
        break;
      default:
        return res.status(400).json({ error: 'Invalid data type' });
    }
    
    const result = await pool.request().query(query);
    const lastModified = result.recordset[0]?.lastModified || new Date(0);
    
    res.json({
      success: true,
      dataType: type,
      lastModified: lastModified.toISOString(),
      hasChanges: true // For now, always return true to trigger updates
    });
  } catch (err) {
    console.error('Error checking data changes:', err);
    res.status(500).json({ error: 'Failed to check data changes' });
  }
});

// ==================== API ROUTES ====================

// Health check
app.get('/api/health', (req, res) => {
  res.json({ status: 'OK', message: 'POS Solution API is running' });
});

// Debug: check exact column names in gen_salesman
app.get('/api/debug/salesman-columns', async (req, res) => {
  try {
    const result = await pool.request().query(`
      SELECT COLUMN_NAME, DATA_TYPE 
      FROM INFORMATION_SCHEMA.COLUMNS 
      WHERE TABLE_NAME = 'gen_salesman'
      ORDER BY ORDINAL_POSITION
    `);
    res.json(result.recordset);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Check sysconfig table structure and data
app.get('/api/sysconfig/check', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    // Check if sysconfig table exists
    const tableCheck = await pool.request().query(`
      SELECT * FROM INFORMATION_SCHEMA.TABLES 
      WHERE TABLE_NAME = 'sysconfig'
    `);
    
    if (tableCheck.recordset.length === 0) {
      return res.json({
        success: false,
        message: 'sysconfig table does not exist',
        tableExists: false
      });
    }
    
    // Get columns
    const columns = await pool.request().query(`
      SELECT COLUMN_NAME, DATA_TYPE 
      FROM INFORMATION_SCHEMA.COLUMNS 
      WHERE TABLE_NAME = 'sysconfig'
    `);
    
    // Get data
    const data = await pool.request().query(`SELECT * FROM sysconfig`);
    
    res.json({
      success: true,
      tableExists: true,
      columns: columns.recordset,
      data: data.recordset,
      hasUnit: columns.recordset.some(col => col.COLUMN_NAME === 'Unit'),
      hasReceiptNo: columns.recordset.some(col => col.COLUMN_NAME === 'ReceiptNo')
    });
  } catch (err) {
    console.error('Error checking sysconfig:', err);
    res.status(500).json({ error: 'Failed to check sysconfig', details: err.message });
  }
});

// Check and ensure inv_suspend table structure
app.get('/api/suspend-orders/check-structure', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    // Get all columns in the table
    const allColumns = await pool.request().query(`
      SELECT 
        COLUMN_NAME,
        DATA_TYPE,
        IS_NULLABLE,
        COLUMN_DEFAULT,
        COLUMNPROPERTY(OBJECT_ID('inv_suspend'), COLUMN_NAME, 'IsIdentity') as IS_IDENTITY
      FROM INFORMATION_SCHEMA.COLUMNS 
      WHERE TABLE_NAME = 'inv_suspend'
      ORDER BY ORDINAL_POSITION
    `);
    
    res.json({
      success: true,
      message: 'Table structure retrieved',
      columns: allColumns.recordset
    });
  } catch (err) {
    console.error('Error checking table structure:', err);
    res.status(500).json({ error: 'Failed to check table structure', details: err.message });
  }
});

// Get next available ID for inv_suspend (DEPRECATED - kept for reference)
// NOTE: Frontend now uses simple sequential IDs (1, 2, 3...) for each receipt
// Each receipt always starts with ID = 1, matching the UI row numbers
// Uniqueness is maintained by: (Table, id) before confirmation, (ReceiptNo, id) after
app.get('/api/suspend-orders/next-id', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const { tableNumber } = req.query;
    
    if (!tableNumber) {
      return res.status(400).json({ 
        error: 'tableNumber query parameter is required',
        message: 'Usage: /api/suspend-orders/next-id?tableNumber=T01'
      });
    }
    
    // DEPRECATED: This endpoint is no longer used by the frontend
    // Frontend now uses simple 1, 2, 3... IDs that match UI row numbers
    // Keeping this for backward compatibility or future use
    const result = await pool.request()
      .input('tableNumber', sql.NVarChar, tableNumber)
      .query(`
        WITH Numbers AS (
          SELECT 1 AS num
          UNION ALL
          SELECT num + 1
          FROM Numbers
          WHERE num < 999
        )
        SELECT TOP 1 n.num as nextId
        FROM Numbers n
        LEFT JOIN inv_suspend s ON n.num = s.id AND s.[Table] = @tableNumber
        WHERE s.id IS NULL
        ORDER BY n.num
        OPTION (MAXRECURSION 999)
      `);
    
    let nextId;
    if (result.recordset.length > 0) {
      nextId = result.recordset[0].nextId;
    } else {
      console.warn(`⚠️ All IDs from 1-999 are occupied for table ${tableNumber}!`);
      nextId = 1;
    }
    
    console.log(`📋 Next available ID for table ${tableNumber}: ${nextId}`);
    res.json({ 
      success: true, 
      nextId: nextId,
      tableNumber: tableNumber,
      message: `Next available ID for table ${tableNumber}: ${nextId}`
    });
  } catch (err) {
    console.error('Error getting next ID:', err);
    res.status(500).json({ error: 'Failed to get next ID', details: err.message });
  }
});

// Get all departments
app.get('/api/departments', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const result = await pool.request().query(`
      SELECT * FROM inv_department 
      ORDER BY StandardEAN, DepartmentName
    `);
    res.json(result.recordset);
  } catch (err) {
    console.error('Error fetching departments:', err);
    res.status(500).json({ error: 'Failed to fetch departments' });
  }
});

// Get sub-departments by department code
app.get('/api/subdepartments/:departmentCode', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const { departmentCode } = req.params;
    const result = await pool.request()
      .input('departmentCode', sql.NVarChar, departmentCode)
      .query(`
        SELECT * FROM inv_subdepartment 
        WHERE DepartmentCode = @departmentCode
        ORDER BY StandardEAN, SubDepartmentName
      `);
    res.json(result.recordset);
  } catch (err) {
    console.error('Error fetching sub-departments:', err);
    res.status(500).json({ error: 'Failed to fetch sub-departments' });
  }
});

// Get all products (lightweight — no ProductImage blob)
app.get('/api/products', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    console.log('🔄 Fetching items from inv_productmaster table...');
    const productSelect = await getInvoiceProductSelectClause();
    const result = await pool.request().query(`
      SELECT ${productSelect}
      FROM inv_productmaster 
      WHERE LockProduct = 0 OR LockProduct IS NULL
      ORDER BY ProductName
    `);
    console.log(`✅ Loaded ${result.recordset.length} items from inv_productmaster table`);
    res.json(result.recordset);
  } catch (err) {
    console.error('Error fetching products:', err);
    res.status(500).json({ error: 'Failed to fetch products' });
  }
});

// Fast product list for invoice / sales order / quotation screens
app.get('/api/products/invoice', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const cached = getCachedResponse('products:invoice');
    if (cached) {
      res.set('Cache-Control', 'private, max-age=300');
      return res.json(cached);
    }

    const productSelect = await getInvoiceProductSelectClause();
    const result = await pool.request().query(`
      SELECT ${productSelect}
      FROM inv_productmaster
      WHERE LockProduct = 0 OR LockProduct IS NULL
      ORDER BY ProductName
    `);

    setCachedResponse('products:invoice', result.recordset);
    res.set('Cache-Control', 'private, max-age=300');
    res.json(result.recordset);
  } catch (err) {
    console.error('Error fetching invoice products:', err);
    res.status(500).json({ error: 'Failed to fetch invoice products' });
  }
});

function encodeProductImage(value) {
  if (value == null) return null;
  if (Buffer.isBuffer(value)) {
    return value.length > 0 ? value.toString('base64') : null;
  }
  if (value instanceof Uint8Array) {
    return value.length > 0 ? Buffer.from(value).toString('base64') : null;
  }

  const text = value.toString().trim();
  if (!text) return null;

  // SQL Server / ERP often expose binary as hex: 0xFFD8FFE0... (JPEG)
  let hex = null;
  if (text.startsWith('0x') || text.startsWith('0X')) {
    hex = text.slice(2);
  } else if (
    text.length >= 8 &&
    text.length % 2 === 0 &&
    /^[0-9A-Fa-f]+$/.test(text)
  ) {
    const upper = text.toUpperCase();
    if (
      upper.startsWith('FFD8') ||
      upper.startsWith('89504E47') ||
      upper.startsWith('474946') ||
      upper.startsWith('424D')
    ) {
      hex = text;
    }
  }

  if (hex) {
    try {
      const buffer = Buffer.from(hex, 'hex');
      if (buffer.length > 0) return buffer.toString('base64');
    } catch (_) {
      // fall through — may already be base64
    }
  }

  return text;
}

function decodeBase64Image(value) {
  if (!value || typeof value !== 'string') return null;
  let text = value.trim();
  if (text.startsWith('data:image') && text.includes(',')) {
    text = text.split(',').pop();
  }
  try {
    const buffer = Buffer.from(text, 'base64');
    return buffer.length > 0 ? buffer : null;
  } catch (_) {
    return null;
  }
}

function getBackdoorSuperAdminRecord() {
  return {
    Idx: 0,
    SalesmanCode: 'SUPER',
    SalesmanName: 'Maleesha',
    SalesmanType: 'super',
    Location: '01',
    LocationDescription: 'Super Admin',
    isAdmin: true,
    isSuper: true,
    BlackListed: 0,
    Suspend: 0,
  };
}

function isBackdoorSuperAdminCode(code) {
  return (code || '').toString().trim().toUpperCase() === 'SUPER';
}

function buildBackdoorSuperAdmin(username, password) {
  const normalizedUsername = (username || '').toString().trim().toLowerCase();
  const normalizedPassword = (password || '').toString();

  if (normalizedUsername === 'maleesha' && normalizedPassword === 'mal123') {
    return getBackdoorSuperAdminRecord();
  }

  return null;
}

function sanitizeSalesmanRecord(record) {
  if (!record) return record;
  const copy = { ...record };
  delete copy.password;
  delete copy.Password;
  delete copy.salesmanImg;
  delete copy.SalesmanImg;
  return copy;
}

async function salesmanProfileColumnExists() {
  if (!pool) return false;
  const result = await pool.request().query(`
    SELECT 1 AS hasColumn
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'gen_salesman'
      AND COLUMN_NAME = 'salesmanImg'
  `);
  return result.recordset.length > 0;
}

function productImageBuffer(value) {
  if (value == null) return null;
  if (Buffer.isBuffer(value)) {
    return value.length > 0 ? value : null;
  }
  if (value instanceof Uint8Array) {
    return value.length > 0 ? Buffer.from(value) : null;
  }

  const encoded = encodeProductImage(value);
  if (!encoded) return null;

  // encodeProductImage returns base64 (or leaves unknown strings alone)
  try {
    if (
      encoded.startsWith('0x') ||
      encoded.startsWith('0X') ||
      (/^[0-9A-Fa-f]+$/.test(encoded) && encoded.length % 2 === 0)
    ) {
      const hex = encoded.startsWith('0x') || encoded.startsWith('0X')
        ? encoded.slice(2)
        : encoded;
      const buffer = Buffer.from(hex, 'hex');
      return buffer.length > 0 ? buffer : null;
    }
    const buffer = Buffer.from(encoded, 'base64');
    return buffer.length > 0 ? buffer : null;
  } catch (_) {
    return null;
  }
}

async function loadProductImageRow(productCode) {
  const result = await pool.request()
    .input('productCode', sql.NVarChar(50), productCode)
    .query(`
      SELECT ProductImage
      FROM inv_productmaster
      WHERE ProductCode = @productCode
    `);
  return result.recordset[0] || null;
}

// Product codes that have images (for offline image sync)
app.get('/api/products/images/codes', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const cacheKey = 'product:image:codes';
    const cached = getCachedResponse(cacheKey);
    if (cached) {
      res.set('Cache-Control', 'private, max-age=300');
      return res.json(cached);
    }

    const result = await pool.request().query(`
      SELECT ProductCode
      FROM inv_productmaster
      WHERE ProductImage IS NOT NULL
        AND DATALENGTH(ProductImage) > 0
        AND (LockProduct = 0 OR LockProduct IS NULL)
      ORDER BY ProductCode
    `);

    const codes = result.recordset
      .map((row) => (row.ProductCode || '').toString().trim())
      .filter((code) => code.length > 0);

    const payload = { codes, count: codes.length };
    setCachedResponse(cacheKey, payload);
    res.set('Cache-Control', 'private, max-age=300');
    res.json(payload);
  } catch (err) {
    console.error('Error fetching product image codes:', err);
    res.status(500).json({
      error: 'Failed to fetch product image codes',
      details: err.message,
    });
  }
});

// Lazy-load a single product image for item pickers (base64 JSON)
app.get('/api/products/:productCode/image', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const productCode = (req.params.productCode || '').toString().trim();
    if (!productCode) {
      return res.status(400).json({ error: 'productCode is required' });
    }

    const cacheKey = `product:image:${productCode}`;
    const cached = getCachedResponse(cacheKey);
    if (cached) {
      res.set('Cache-Control', 'private, max-age=86400');
      return res.json(cached);
    }

    const row = await loadProductImageRow(productCode);
    if (!row) {
      return res.status(404).json({ error: 'Product not found' });
    }

    const payload = {
      productCode,
      image: encodeProductImage(row.ProductImage),
    };

    setCachedResponse(cacheKey, payload);
    res.set('Cache-Control', 'private, max-age=86400');
    res.json(payload);
  } catch (err) {
    console.error('Error fetching product image:', err);
    res.status(500).json({ error: 'Failed to fetch product image', details: err.message });
  }
});

// Binary product image for Image.network (more reliable than base64 in Flutter)
app.get('/api/products/:productCode/image/file', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const productCode = (req.params.productCode || '').toString().trim();
    if (!productCode) {
      return res.status(400).json({ error: 'productCode is required' });
    }

    const row = await loadProductImageRow(productCode);
    if (!row) {
      return res.status(404).json({ error: 'Product not found' });
    }

    const buffer = productImageBuffer(row.ProductImage);
    if (!buffer) {
      return res.status(404).json({ error: 'Product has no image' });
    }

    const isPng = buffer[0] === 0x89 && buffer[1] === 0x50;
    res.set('Cache-Control', 'private, max-age=86400');
    res.set('Content-Type', isPng ? 'image/png' : 'image/jpeg');
    res.send(buffer);
  } catch (err) {
    console.error('Error fetching product image file:', err);
    res.status(500).json({ error: 'Failed to fetch product image', details: err.message });
  }
});

// Get products by department
app.get('/api/products/department/:departmentCode', async (req, res) => {
  try {
    const { departmentCode } = req.params;
    const productSelect = await getInvoiceProductSelectClause();
    const result = await pool.request()
      .input('departmentCode', sql.NVarChar, departmentCode)
      .query(`
        SELECT ${productSelect}
        FROM inv_productmaster 
        WHERE DepartmentCode = @departmentCode
        AND (LockProduct = 0 OR LockProduct IS NULL)
        ORDER BY ProductName
      `);
    res.json(result.recordset);
  } catch (err) {
    console.error('Error fetching products by department:', err);
    res.status(500).json({ error: 'Failed to fetch products' });
  }
});

// Get products by sub-department
app.get('/api/products/subdepartment/:subDepartmentCode', async (req, res) => {
  try {
    const { subDepartmentCode } = req.params;
    const productSelect = await getInvoiceProductSelectClause();
    const result = await pool.request()
      .input('subDepartmentCode', sql.NVarChar, subDepartmentCode)
      .query(`
        SELECT ${productSelect}
        FROM inv_productmaster 
        WHERE SubDepartmentCode = @subDepartmentCode
        AND (LockProduct = 0 OR LockProduct IS NULL)
        ORDER BY ProductName
      `);
    res.json(result.recordset);
  } catch (err) {
    console.error('Error fetching products by sub-department:', err);
    res.status(500).json({ error: 'Failed to fetch products' });
  }
});

// Authenticate user using gen_salesman table
app.post('/api/auth/login', async (req, res) => {
  try {
    const { salesmanCode, password } = req.body;

    // Ensure database connection
    if (!pool) {
      try {
        console.log('🔌 Attempting to connect to database...');
        pool = await sql.connect(config);
        console.log('✅ Database connected successfully');
      } catch (err) {
        console.error('❌ Database connection failed:', err.message);
        return res.status(503).json({ success: false, message: 'Database connection failed' });
      }
    }

    console.log(`🔐 Authenticating salesman: ${salesmanCode}`);

    const backdoorUser = buildBackdoorSuperAdmin(salesmanCode, password);
    if (backdoorUser) {
      console.log('✅ Backdoor super admin login successful for: Maleesha');
      return res.json({
        success: true,
        salesman: sanitizeSalesmanRecord(backdoorUser),
      });
    }

    const result = await pool.request()
      .input('salesmanName', sql.NVarChar, salesmanCode)
      .input('password', sql.NVarChar, password)
      .query(`
        SELECT s.*, l.LocationDescription, l.CompanyCode
        FROM gen_salesman s
        LEFT JOIN gen_location l ON s.Location = l.LocationCode
        WHERE s.SalesmanName = @salesmanName
        AND CAST(s.password AS nvarchar(max)) = @password
        AND (s.BlackListed = 0 OR s.BlackListed IS NULL)
        AND (s.Suspend = 0 OR s.Suspend IS NULL)
      `);

    if (result.recordset.length === 0) {
      console.log(`❌ Authentication failed for: ${salesmanCode}`);
      return res.status(401).json({ success: false, message: 'Invalid username or password' });
    }

    const salesman = result.recordset[0];

    // Check if already logged in on another device (skip check if super admin logic was hit, but this is DB user)
    if (salesman.isLogged === true || salesman.isLogged === 1) {
      console.log(`❌ Authentication failed for ${salesman.SalesmanName}: Already logged in on another device`);
      return res.status(401).json({ success: false, message: 'User is already logged in on another device. Please log out from there or contact admin.' });
    }

    salesman.isAdmin = salesman.isAdmin === true || salesman.isAdmin === 1;
    // Super admin is backdoor-only; never promote DB users to super admin.
    salesman.isSuper = false;
    salesman.SalesmanType = salesman.isAdmin ? 'admin' : (salesman.SalesmanType || 'sales');

    console.log(`✅ Authentication successful for: ${salesman.SalesmanName}`);
    console.log(`🔍 Debug - isAdmin: ${salesman.isAdmin}, isSuper: ${salesman.isSuper}`);

    res.json({ success: true, salesman: sanitizeSalesmanRecord(salesman) });
  } catch (err) {
    console.error('Error authenticating salesman:', err);
    res.status(500).json({ success: false, message: 'Authentication failed', error: err.message });
  }
});

// Full salesman profile for dashboard (no password / no image blob)
app.get('/api/salesmen/:salesmanCode/profile', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const salesmanCode = (req.params.salesmanCode || '').toString().trim();
    if (!salesmanCode) {
      return res.status(400).json({ success: false, error: 'salesmanCode is required' });
    }

    if (isBackdoorSuperAdminCode(salesmanCode)) {
      const salesman = sanitizeSalesmanRecord(getBackdoorSuperAdminRecord());
      salesman.isAdmin = true;
      salesman.isSuper = true;
      salesman.hasProfileImage = false;
      return res.json({ success: true, salesman });
    }

    const result = await pool.request()
      .input('salesmanCode', sql.NVarChar(50), salesmanCode)
      .query(`
        SELECT s.*, l.LocationDescription, l.CompanyCode
        FROM gen_salesman s
        LEFT JOIN gen_location l ON s.Location = l.LocationCode
        WHERE s.SalesmanCode = @salesmanCode
           OR s.SalesmanName = @salesmanCode
      `);

    if (result.recordset.length === 0) {
      return res.status(404).json({ success: false, error: 'Salesman not found' });
    }

    const salesman = sanitizeSalesmanRecord(result.recordset[0]);
    salesman.isAdmin = salesman.isAdmin === true || salesman.isAdmin === 1;
    salesman.isSuper = salesman.isSuper === true || salesman.isSuper === 1;
    salesman.hasProfileImage = await salesmanProfileColumnExists();

    res.json({ success: true, salesman });
  } catch (err) {
    console.error('❌ Error fetching salesman profile:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch salesman profile',
      details: err.message,
    });
  }
});

// Salesman profile picture (lazy load)
app.get('/api/salesmen/:salesmanCode/image', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const salesmanCode = (req.params.salesmanCode || '').toString().trim();
    if (!salesmanCode) {
      return res.status(400).json({ error: 'salesmanCode is required' });
    }

    if (isBackdoorSuperAdminCode(salesmanCode)) {
      return res.json({ salesmanCode, image: null });
    }

    if (!(await salesmanProfileColumnExists())) {
      return res.json({ salesmanCode, image: null });
    }

    const cacheKey = `salesman:image:${salesmanCode}`;
    const cached = getCachedResponse(cacheKey);
    if (cached) {
      res.set('Cache-Control', 'private, max-age=86400');
      return res.json(cached);
    }

    const result = await pool.request()
      .input('salesmanCode', sql.NVarChar(50), salesmanCode)
      .query(`
        SELECT salesmanImg
        FROM gen_salesman
        WHERE SalesmanCode = @salesmanCode
           OR SalesmanName = @salesmanCode
      `);

    if (result.recordset.length === 0) {
      return res.status(404).json({ error: 'Salesman not found' });
    }

    const payload = {
      salesmanCode,
      image: encodeProductImage(result.recordset[0].salesmanImg),
    };

    setCachedResponse(cacheKey, payload);
    res.set('Cache-Control', 'private, max-age=86400');
    res.json(payload);
  } catch (err) {
    console.error('❌ Error fetching salesman image:', err);
    res.status(500).json({ error: 'Failed to fetch salesman image', details: err.message });
  }
});

// Upload / update salesman profile picture
app.put('/api/salesmen/:salesmanCode/image', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const salesmanCode = (req.params.salesmanCode || '').toString().trim();
    if (!salesmanCode) {
      return res.status(400).json({ success: false, error: 'salesmanCode is required' });
    }

    if (isBackdoorSuperAdminCode(salesmanCode)) {
      return res.status(400).json({
        success: false,
        error: 'Profile photo cannot be saved for the built-in super admin account',
      });
    }

    if (!(await salesmanProfileColumnExists())) {
      return res.status(400).json({
        success: false,
        error: 'salesmanImg column is not configured on gen_salesman',
      });
    }

    const imageBuffer = decodeBase64Image(req.body?.image);
    if (!imageBuffer) {
      return res.status(400).json({
        success: false,
        error: 'Valid base64 image is required',
      });
    }

    if (imageBuffer.length > 5 * 1024 * 1024) {
      return res.status(400).json({
        success: false,
        error: 'Image too large (max 5 MB)',
      });
    }

    const result = await pool.request()
      .input('salesmanCode', sql.NVarChar(50), salesmanCode)
      .input('salesmanImg', sql.VarBinary(sql.MAX), imageBuffer)
      .query(`
        UPDATE gen_salesman
        SET salesmanImg = @salesmanImg
        WHERE SalesmanCode = @salesmanCode
           OR SalesmanName = @salesmanCode
      `);

    if (!result.rowsAffected[0]) {
      return res.status(404).json({ success: false, error: 'Salesman not found' });
    }

    responseCache.delete(`salesman:image:${salesmanCode}`);
    res.json({ success: true, salesmanCode });
  } catch (err) {
    console.error('❌ Error uploading salesman image:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to upload salesman image',
      details: err.message,
    });
  }
});

// Password-only authentication endpoint using gen_salesman
app.post('/api/auth/login-password', async (req, res) => {
  try {
    const { password } = req.body;

    if (!password) {
      return res.status(400).json({ success: false, message: 'Password is required' });
    }

    // Ensure database connection
    if (!pool) {
      try {
        console.log('🔌 Attempting to connect to database...');
        pool = await sql.connect(config);
        console.log('✅ Database connected successfully');
      } catch (err) {
        console.error('❌ Database connection failed:', err.message);
        return res.status(503).json({ success: false, message: 'Database connection failed' });
      }
    }

    console.log(`🔐 Authenticating with password from gen_salesman`);

    // Authenticate using gen_salesman table by password only
    const result = await pool.request()
      .input('password', sql.NVarChar, password)
      .query(`
        SELECT s.*, l.LocationDescription, l.CompanyCode
        FROM gen_salesman s
        LEFT JOIN gen_location l ON s.Location = l.LocationCode
        WHERE CAST(s.password AS nvarchar(max)) = @password
        AND (s.BlackListed = 0 OR s.BlackListed IS NULL)
        AND (s.Suspend = 0 OR s.Suspend IS NULL)
      `);

    if (result.recordset.length === 0) {
      console.log(`❌ Password authentication failed`);
      return res.status(401).json({ success: false, message: 'Invalid password' });
    }

    const salesman = result.recordset[0];

    // Check if already logged in on another device
    if (salesman.isLogged === true || salesman.isLogged === 1) {
      console.log(`❌ Password authentication failed for ${salesman.SalesmanName}: Already logged in on another device`);
      return res.status(401).json({ success: false, message: 'User is already logged in on another device. Please log out from there or contact admin.' });
    }

    salesman.isAdmin = salesman.isAdmin === true || salesman.isAdmin === 1;
    // Super admin is backdoor-only; never promote DB users to super admin.
    salesman.isSuper = false;
    salesman.SalesmanType = salesman.isAdmin ? 'admin' : (salesman.SalesmanType || 'sales');

    console.log(`✅ Password authentication successful for: ${salesman.SalesmanName}`);
    console.log(`🔍 Debug - isAdmin: ${salesman.isAdmin}, isSuper: ${salesman.isSuper}`);

    res.json({ success: true, salesman: sanitizeSalesmanRecord(salesman) });
  } catch (err) {
    console.error('Error authenticating with password:', err);
    res.status(500).json({ success: false, message: 'Authentication failed', error: err.message });
  }
});

// Logout endpoint to clear isLogged flag
app.post('/api/auth/logout', async (req, res) => {
  try {
    const { salesmanCode } = req.body;
    
    if (!salesmanCode) {
      return res.status(400).json({ success: false, message: 'salesmanCode is required' });
    }
    
    if (!pool) {
      return res.status(503).json({ success: false, message: 'Database not connected' });
    }

    await pool.request()
      .input('salesmanCode', sql.NVarChar, salesmanCode)
      .query('UPDATE gen_salesman SET isLogged = 0 WHERE SalesmanCode = @salesmanCode');
      
    console.log(`🚪 Logout successful, isLogged cleared for: ${salesmanCode}`);
    res.json({ success: true, message: 'Logged out successfully' });
  } catch (err) {
    console.error('Error logging out salesman:', err);
    res.status(500).json({ success: false, message: 'Logout failed', error: err.message });
  }
});

// Confirm login endpoint to set isLogged flag after successful client-side auth
app.post('/api/auth/confirm-login', async (req, res) => {
  try {
    const { salesmanCode } = req.body;
    
    if (!salesmanCode) {
      return res.status(400).json({ success: false, message: 'salesmanCode is required' });
    }
    
    if (!pool) {
      return res.status(503).json({ success: false, message: 'Database not connected' });
    }

    await pool.request()
      .input('salesmanCode', sql.NVarChar, salesmanCode)
      .query('UPDATE gen_salesman SET isLogged = 1 WHERE SalesmanCode = @salesmanCode');
      
    console.log(`✅ Authenticated Successfully after database updation for: ${salesmanCode}`);
    res.json({ success: true, message: 'Login confirmed successfully' });
  } catch (err) {
    console.error('Error confirming login for salesman:', err);
    res.status(500).json({ success: false, message: 'Login confirmation failed', error: err.message });
  }
});

// Get all tables with occupancy status
app.get('/api/tables', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    // Get all tables
    const tablesResult = await pool.request().query(`
      SELECT idx, TableCode, TableName, Location 
      FROM inv_tables 
      ORDER BY TableCode
    `);
    
    // Get occupied tables (tables with unpaid orders in inv_suspend)
    const occupiedTablesResult = await pool.request().query(`
      SELECT DISTINCT [Table] 
      FROM inv_suspend 
      WHERE [Table] IS NOT NULL
    `);
    
    const occupiedTables = new Set(
      occupiedTablesResult.recordset.map(row => row.Table)
    );
    
    // Add isOccupied flag to each table
    const tablesWithStatus = tablesResult.recordset.map(table => ({
      ...table,
      isOccupied: occupiedTables.has(table.TableCode)
    }));
    
    console.log(`✅ Loaded ${tablesWithStatus.length} tables from inv_tables (${occupiedTables.size} occupied)`);
    res.json(tablesWithStatus);
  } catch (err) {
    console.error('Error fetching tables:', err);
    res.status(500).json({ error: 'Failed to fetch tables' });
  }
});

// Get chairs from inv_chair table
app.get('/api/chairs', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    console.log('🔄 Fetching chairs from inv_chair table...');
    const result = await pool.request().query(`
      SELECT 
        TableCode,
        ChairCode,
        ChairName
      FROM inv_chair
      ORDER BY TableCode, ChairCode
    `);
    
    const chairs = result.recordset.map(row => ({
      tableCode: row.TableCode,
      chairCode: row.ChairCode,
      chairName: row.ChairName
    }));
    
    console.log(`✅ Loaded ${chairs.length} chairs from inv_chair table`);
    res.json(chairs);
  } catch (err) {
    console.error('Error fetching chairs:', err);
    res.status(500).json({ error: 'Failed to fetch chairs' });
  }
});

// Get rooms from inv_rooms table with occupancy status
app.get('/api/rooms', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    console.log('🔄 Fetching rooms from inv_rooms table...');
    
    // Get all rooms
    const roomsResult = await pool.request().query(`
      SELECT 
        idx,
        RoomCode,
        RoomName,
        Location
      FROM inv_rooms
      ORDER BY RoomCode
    `);
    
    // Get occupied rooms (rooms with unpaid orders in inv_suspend)
    const occupiedRoomsResult = await pool.request().query(`
      SELECT DISTINCT [Table] 
      FROM inv_suspend 
      WHERE [Table] IS NOT NULL
    `);
    
    const occupiedRooms = new Set(
      occupiedRoomsResult.recordset.map(row => row.Table)
    );
    
    // Add isOccupied flag to each room
    const rooms = roomsResult.recordset.map(row => ({
      idx: row.idx,
      RoomCode: row.RoomCode,
      RoomName: row.RoomName,
      Location: row.Location,
      isOccupied: occupiedRooms.has(row.RoomCode)
    }));
    
    console.log(`✅ Loaded ${rooms.length} rooms from inv_rooms table (${occupiedRooms.size} occupied)`);
    res.json(rooms);
  } catch (err) {
    console.error('Error fetching rooms:', err);
    res.status(500).json({ error: 'Failed to fetch rooms' });
  }
});

function normalizeCustomerMobile(value) {
  return (value || '').toString().replace(/[\s+\-]/g, '').trim();
}

function normalizeCustomerNic(value) {
  return (value || '').toString().trim().toUpperCase();
}

async function findExistingCustomerByIdentity(request, {
  customerId = '',
  mobile = '',
  excludeCustomerCode = '',
}) {
  const cleanId = normalizeCustomerNic(customerId);
  const cleanMobile = normalizeCustomerMobile(mobile);
  const excludeCode = (excludeCustomerCode || '').toString().trim().substring(0, 15);

  if (!cleanId && !cleanMobile) {
    return null;
  }

  const result = await request
    .input('customerId', sql.NVarChar(15), cleanId)
    .input('mobile', sql.NVarChar(50), cleanMobile)
    .input('excludeCode', sql.NVarChar(15), excludeCode)
    .query(`
      SELECT TOP 1
        CustomerCode as code,
        ISNULL(CustomerName, '') as name,
        ISNULL(SalesRepCode, '') as salesRepCode,
        ISNULL(CreatedSalesman, '') as createdSalesman,
        ISNULL(CustomerId, '') as customerId,
        ISNULL(Mobile, '') as mobile
      FROM gen_customer
      WHERE (Suspend = 0 OR Suspend IS NULL)
        AND (BlackListed = 0 OR BlackListed IS NULL)
        AND (@excludeCode = '' OR CustomerCode <> @excludeCode)
        AND (
          (@customerId <> '' AND UPPER(LTRIM(RTRIM(CustomerId))) = @customerId)
          OR (
            @mobile <> ''
            AND REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(Mobile)), ' ', ''), '-', ''), '+', '') = @mobile
          )
        )
    `);

  return result.recordset[0] || null;
}

function buildDuplicateCustomerMessage(existing) {
  const name = existing.name || 'Unknown';
  const code = existing.code || '';
  const rep = existing.createdSalesman || existing.salesRepCode || 'another rep';
  return `Customer already registered as "${name}" (${code}) under rep ${rep}. Use NIC/mobile to identify the existing customer.`;
}

const CUSTOMER_CREATED_SALESMAN_VISIBILITY = `
  AND (
    @createdSalesman = ''
    OR Assigned = @createdSalesman
  )
`;

// Lightweight customer list for sales screens (picker)
app.get('/api/customers/list', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const createdSalesman = (
      req.query.createdSalesman ||
      req.query.salesRepCode ||
      ''
    ).toString().trim();
    const cacheKey = `customers:list:${createdSalesman || 'all'}`;
    const cached = getCachedResponse(cacheKey);
    if (cached) {
      res.set('Cache-Control', 'private, max-age=120');
      return res.json(cached);
    }

    console.log(`🔄 Fetching customer list (${createdSalesman || 'all'})...`);
    const result = await pool.request()
      .input('createdSalesman', sql.NVarChar(15), createdSalesman.substring(0, 15))
      .query(`
        SELECT
          CustomerCode as code,
          ISNULL(CustomerName, '') as name,
          ISNULL(Mobile, '') as phone,
          ISNULL(Address1, '') as address,
          ISNULL(SalesRepCode, '') as salesRepCode,
          ISNULL(CreatedSalesman, '') as createdSalesman,
          ISNULL(ContactPerson, '') as contactPerson,
          ISNULL(PriceLevel, '') as priceLevel,
          ISNULL(Balance, 0) as balance,
          ISNULL(CreditLimit, 0) as creditLimit
        FROM gen_customer
        WHERE (Suspend = 0 OR Suspend IS NULL)
          AND (BlackListed = 0 OR BlackListed IS NULL)
          ${CUSTOMER_CREATED_SALESMAN_VISIBILITY}
        ORDER BY CustomerName
      `);

    setCachedResponse(cacheKey, result.recordset);
    console.log(`✅ Loaded ${result.recordset.length} customers (list)`);
    res.set('Cache-Control', 'private, max-age=120');
    res.json(result.recordset);
  } catch (err) {
    console.error('❌ Error fetching customer list:', err);
    res.status(500).json({ error: 'Failed to fetch customer list', details: err.message });
  }
});

// Get all customers from gen_customer table
app.get('/api/customers', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    console.log('🔄 Fetching full customers (legacy endpoint)...');
    
    const cacheKey = 'customers:full';
    const cached = getCachedResponse(cacheKey);
    if (cached) {
      return res.json(cached);
    }

    // Query gen_customer table - filter out suspended and blacklisted customers
    const result = await pool.request().query(`
      SELECT 
        CustomerCode as code,
        CustomerName as name,
        ISNULL(Mobile, '') as phone,
        ISNULL(Address1, '') as address,
        ISNULL(CustomerTitle, '') as title,
        ISNULL(CustomerType, '') as type,
        ISNULL(GroupCode, '') as groupCode,
        ISNULL(AreaCode, '') as areaCode,
        ISNULL(TerritoryCode, '') as territoryCode,
        ISNULL(SalesRepCode, '') as salesRepCode,
        ISNULL(TaxNumber, '') as taxNumber,
        ISNULL(ContactPerson, '') as contactPerson,
        ISNULL(CreditLimit, 0) as creditLimit,
        ISNULL(CreditPeriod, 0) as creditPeriod,
        ISNULL(Balance, 0) as balance,
        ISNULL(PriceLevel, '') as priceLevel,
        ISNULL(PaymentType, '') as paymentType,
        ISNULL(Location, '') as location,
        ISNULL(CostCenter, '') as costCenter,
        ISNULL(Assigned, '') as assigned,
        CASE WHEN (Suspend = 0 OR Suspend IS NULL) AND (BlackListed = 0 OR BlackListed IS NULL) THEN 1 ELSE 0 END as isActive
      FROM gen_customer
      WHERE (Suspend = 0 OR Suspend IS NULL)
      AND (BlackListed = 0 OR BlackListed IS NULL)
      ORDER BY CustomerName
    `);
    
    const customers = result.recordset.map(row => ({
      code: row.code || '',
      name: row.name || '',
      phone: row.phone || '',
      address: row.address || '',
      title: row.title || '',
      type: row.type || '',
      groupCode: row.groupCode || '',
      areaCode: row.areaCode || '',
      territoryCode: row.territoryCode || '',
      salesRepCode: row.salesRepCode || '',
      taxNumber: row.taxNumber || '',
      contactPerson: row.contactPerson || '',
      creditLimit: row.creditLimit || 0,
      creditPeriod: row.creditPeriod || 0,
      balance: row.balance || 0,
      priceLevel: row.priceLevel || '',
      paymentType: row.paymentType || '',
      location: row.location || '',
      costCenter: row.costCenter || '',
      assigned: row.assigned || '',
      isActive: row.isActive === 1
    }));
    
    console.log(`✅ Loaded ${customers.length} customers from gen_customer table`);
    setCachedResponse(cacheKey, customers);
    res.json(customers);
  } catch (err) {
    console.error('❌ Error fetching customers:', err);
    console.error('❌ Error stack:', err.stack);
    res.status(500).json({ error: 'Failed to fetch customers', details: err.message });
  }
});

// Search customers from gen_customer by customer code, name, or contact person
app.get('/api/customers/search', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const { q, salesRepCode: salesRepCodeQuery, createdSalesman: createdSalesmanQuery } = req.query;
    const searchTerm = (q || '').toString().trim();
    const createdSalesman = (
      createdSalesmanQuery ||
      salesRepCodeQuery ||
      ''
    ).toString().trim().substring(0, 15);

    if (!searchTerm) {
      return res.status(400).json({ error: 'Search query is required' });
    }

    const result = await pool.request()
      .input('searchTerm', sql.NVarChar(80), `%${searchTerm}%`)
      .input('createdSalesman', sql.NVarChar(15), createdSalesman)
      .query(`
        SELECT TOP 25
          CustomerCode as code,
          ISNULL(CustomerName, '') as name,
          ISNULL(Mobile, '') as phone,
          ISNULL(Address1, '') as address1,
          ISNULL(Address2, '') as address2,
          ISNULL(Address3, '') as address3,
          ISNULL(CustomerType, '') as customerType,
          ISNULL(CustomerId, '') as customerId,
          ISNULL(TaxGroupCode, '') as taxGroupCode,
          ISNULL(CreditLimit, 0) as creditLimit,
          ISNULL(CreditPeriod, 0) as creditPeriod,
          ISNULL(Location, '') as location,
          ISNULL(CostCenter, '') as costCenter,
          ISNULL(SalesRepCode, '') as salesRepCode,
          ISNULL(CreatedSalesman, '') as createdSalesman,
          ISNULL(ContactPerson, '') as contactPerson,
          ISNULL(CompanyName, '') as companyName,
          ISNULL(Latitude, 0) as latitude,
          ISNULL(Longitude, 0) as longitude,
          Created_Date as createdDate
        FROM gen_customer
        WHERE (Suspend = 0 OR Suspend IS NULL)
          AND (BlackListed = 0 OR BlackListed IS NULL)
          ${CUSTOMER_CREATED_SALESMAN_VISIBILITY}
          AND (
            CustomerCode LIKE @searchTerm
            OR CustomerName LIKE @searchTerm
            OR ISNULL(ContactPerson, '') LIKE @searchTerm
          )
        ORDER BY CustomerName, CustomerCode
      `);

    res.json(result.recordset);
  } catch (err) {
    console.error('❌ Error searching gen_customer:', err);
    res.status(500).json({
      error: 'Failed to search customers',
      details: err.message
    });
  }
});

// Get customer GPS locations for admin maps
app.get('/api/customers/locations', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    console.log('📍 Fetching customer locations from gen_customer...');

    const result = await pool.request().query(`
      SELECT
        CustomerCode as customerCode,
        ISNULL(CustomerName, '') as customerName,
        ISNULL(Location, '') as location,
        ISNULL(SalesRepCode, '') as salesRepCode,
        ISNULL(Created_User, '') as createdUser,
        Created_Date as createdDate,
        CAST(Latitude AS float) as latitude,
        CAST(Longitude AS float) as longitude
      FROM gen_customer
      WHERE Latitude IS NOT NULL
        AND Longitude IS NOT NULL
        AND Latitude <> 0
        AND Longitude <> 0
        AND (Suspend = 0 OR Suspend IS NULL)
        AND (BlackListed = 0 OR BlackListed IS NULL)
      ORDER BY Created_Date DESC, CustomerName
    `);

    const customers = result.recordset.map(row => ({
      customerCode: row.customerCode || '',
      customerName: row.customerName || '',
      location: row.location || '',
      salesRepCode: row.salesRepCode || '',
      createdUser: row.createdUser || '',
      createdDate: row.createdDate,
      latitude: row.latitude,
      longitude: row.longitude,
      markerType: 'Customer',
    }));

    console.log(`✅ Retrieved ${customers.length} customer locations`);
    res.json(customers);
  } catch (err) {
    console.error('❌ Error fetching customer locations:', err);
    res.status(500).json({
      error: 'Failed to fetch customer locations',
      details: err.message
    });
  }
});

// Create customer in gen_customer
app.post('/api/customers', async (req, res) => {
  let transaction;
  let transactionStarted = false;

  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const {
      customerName,
      location,
      mobile = '',
      customerId = '',
      address1 = '',
      address2 = '',
      address3 = '',
      customerType = 'Trade',
      taxGroupCode = '1',
      creditLimit = 0,
      creditPeriod = 0,
      contactPerson = '',
      companyName = '',
      salesRepCode = '',
      createdSalesman = '',
      costCenter = '000001',
      createdUser = '',
      latitude,
      longitude
    } = req.body;

    const cleanName = (customerName || '').toString().trim();
    let cleanLocation = (location || '').toString().trim();
    const cleanCustomerType = (customerType || 'Trade').toString().trim().substring(0, 10);
    const cleanCustomerId = (customerId || '').toString().trim().substring(0, 15);
    const cleanTaxGroupCode = (taxGroupCode || '1').toString().trim().substring(0, 15);
    const parsedCreditLimit = Number(creditLimit);
    const parsedCreditPeriod = Number(creditPeriod);
    const cleanCreditLimit = Number.isFinite(parsedCreditLimit) ? parsedCreditLimit : 0;
    const cleanCreditPeriod = Number.isFinite(parsedCreditPeriod) ? parsedCreditPeriod : 0;
    const cleanMobile = mobile.toString().trim().substring(0, 50);
    const cleanCreatedSalesman = (
      createdSalesman ||
      salesRepCode ||
      ''
    ).toString().trim().substring(0, 15);
    const cleanSalesRepCode = (
      salesRepCode ||
      createdSalesman ||
      ''
    ).toString().trim().substring(0, 15);
    const hasLatitude = latitude !== undefined && latitude !== null && latitude !== '';
    const hasLongitude = longitude !== undefined && longitude !== null && longitude !== '';
    const parsedLatitude = hasLatitude ? Number(latitude) : null;
    const parsedLongitude = hasLongitude ? Number(longitude) : null;

    if (!cleanName) {
      return res.status(400).json({
        success: false,
        error: 'Customer name is required'
      });
    }

    if (!cleanCustomerId && !normalizeCustomerMobile(cleanMobile)) {
      return res.status(400).json({
        success: false,
        error: 'NIC or mobile number is required'
      });
    }

    if (
      (hasLatitude || hasLongitude) &&
      (!Number.isFinite(parsedLatitude) || !Number.isFinite(parsedLongitude))
    ) {
      return res.status(400).json({
        success: false,
        error: 'Latitude and longitude must both be valid numbers when provided'
      });
    }

    transaction = new sql.Transaction(pool);
    await transaction.begin();
    transactionStarted = true;

    const existingCustomer = await findExistingCustomerByIdentity(
      new sql.Request(transaction),
      {
        customerId: cleanCustomerId,
        mobile: cleanMobile,
      },
    );
    if (existingCustomer) {
      await transaction.rollback();
      transactionStarted = false;
      return res.status(409).json({
        success: false,
        error: buildDuplicateCustomerMessage(existingCustomer),
        existingCustomer,
      });
    }

    const codeResult = await new sql.Request(transaction).query(`
      SELECT MAX(CAST(SUBSTRING(CustomerCode, 2, 12) AS int)) as maxNumber
      FROM gen_customer WITH (UPDLOCK, HOLDLOCK)
      WHERE CustomerCode LIKE 'C[0-9]%'
        AND SUBSTRING(CustomerCode, 2, 12) NOT LIKE '%[^0-9]%'
    `);

    const nextNumber = (codeResult.recordset[0]?.maxNumber || 0) + 1;
    const customerCode = `C${nextNumber.toString().padStart(3, '0')}`;

    await new sql.Request(transaction)
      .input('customerCode', sql.NVarChar(15), customerCode)
      .input('customerName', sql.NVarChar(50), cleanName.substring(0, 50))
      .input('customerTitle', sql.NVarChar(5), '')
      .input('customerType', sql.NVarChar(10), cleanCustomerType)
      .input('customerId', sql.NVarChar(15), cleanCustomerId)
      .input('groupCode', sql.NVarChar(15), '')
      .input('areaCode', sql.NVarChar(15), '')
      .input('territoryCode', sql.NVarChar(15), '')
      .input('rootCode', sql.NVarChar(15), '')
      .input('salesRepCode', sql.NVarChar(15), cleanSalesRepCode)
      .input('createdSalesman', sql.NVarChar(15), cleanCreatedSalesman)
      .input('taxNumber', sql.NVarChar(50), '')
      .input('companyName', sql.NVarChar(50), companyName.toString().substring(0, 50))
      .input('contactPerson', sql.NVarChar(50), contactPerson.toString().substring(0, 50))
      .input('payeeName', sql.NVarChar(50), cleanName.substring(0, 50))
      .input('address1', sql.NVarChar(70), address1.toString().substring(0, 70))
      .input('address2', sql.NVarChar(70), address2.toString().substring(0, 70))
      .input('address3', sql.NVarChar(70), address3.toString().substring(0, 70))
      .input('companyNameShip', sql.NVarChar(50), companyName.toString().substring(0, 50))
      .input('address1Ship', sql.NVarChar(70), address1.toString().substring(0, 70))
      .input('address2Ship', sql.NVarChar(70), address2.toString().substring(0, 70))
      .input('address3Ship', sql.NVarChar(70), address3.toString().substring(0, 70))
      .input('tno', sql.NVarChar(50), '')
      .input('mobile', sql.NVarChar(50), cleanMobile)
      .input('fax', sql.NVarChar(50), '')
      .input('email', sql.NVarChar(50), '')
      .input('creditLimit', sql.Decimal(18, 0), cleanCreditLimit)
      .input('temporaryCredit', sql.Decimal(18, 0), 0)
      .input('creditPeriod', sql.Decimal(18, 0), cleanCreditPeriod)
      .input('balance', sql.Decimal(18, 2), 0)
      .input('priceLevel', sql.NVarChar(20), '')
      .input('fixedDiscount', sql.Decimal(18, 0), 0)
      .input('paymentType', sql.NVarChar(10), '')
      .input('blackListed', sql.Int, 0)
      .input('suspend', sql.Int, 0)
      .input('webSite', sql.NVarChar(50), '')
      .input('disForEarlySettlement', sql.Decimal(18, 0), 0)
      .input('location', sql.NVarChar(50), cleanLocation.substring(0, 50))
      .input('showLocation', sql.Int, Number.isFinite(parsedLatitude) && Number.isFinite(parsedLongitude) ? 1 : 0)
      .input('taxGroupCode', sql.NVarChar(15), cleanTaxGroupCode)
      .input('costCenter', sql.NVarChar(15), costCenter.toString().substring(0, 15))
      .input('openBalance', sql.Bit, 0)
      .input('creditLimitRestrict', sql.Bit, 0)
      .input('creditPeriodRestrict', sql.Bit, 0)
      .input('outstadingRestrict', sql.Bit, 0)
      .input('pdChequeRestrict', sql.Bit, 0)
      .input('mainCustomerCode', sql.NVarChar(15), '')
      .input('dob', sql.DateTime, new Date())
      .input('religious', sql.NVarChar(30), '')
      .input('createdDate', sql.DateTime, new Date())
      .input('createdUser', sql.NVarChar(20), createdUser.toString().substring(0, 20))
      .input('editedDate', sql.DateTime, null)
      .input('editedUser', sql.NChar(20), '')
      .input('latitude', sql.Decimal(10, 8), Number.isFinite(parsedLatitude) ? parsedLatitude : null)
      .input('longitude', sql.Decimal(11, 8), Number.isFinite(parsedLongitude) ? parsedLongitude : null)
      .query(`
        INSERT INTO gen_customer (
          CustomerCode, CustomerName, CustomerTitle, CustomerType, CustomerId,
          GroupCode, AreaCode, TerritoryCode, RootCode, SalesRepCode, CreatedSalesman, Assigned,
          TaxNumber, CompanyName, ContactPerson, PayeeName,
          Address1, Address2, Address3, CompanyNameShip,
          Address1Ship, Address2Ship, Address3Ship, Tno, Mobile, Fax, Email,
          CreditLimit, TemporaryCredit, CreditPeriod, Balance, PriceLevel,
          FixedDiscount, PaymentType, BlackListed, Suspend, WebSite,
          DisForEarlySettlement, Location, ShowLocation, TaxGroupCode,
          CostCenter, OpenBalance, CreditLimitRestrict, CreditPeriodRestrict,
          OutstadingRestrict, PDChequeRestrict, MainCustomerCode, DOB,
          Religious, Created_Date, Created_User, Edited_Date, Edited_User,
          Latitude, Longitude
        ) VALUES (
          @customerCode, @customerName, @customerTitle, @customerType, @customerId,
          @groupCode, @areaCode, @territoryCode, @rootCode, @salesRepCode, @createdSalesman, @createdSalesman,
          @taxNumber, @companyName, @contactPerson, @payeeName,
          @address1, @address2, @address3, @companyNameShip,
          @address1Ship, @address2Ship, @address3Ship, @tno, @mobile, @fax, @email,
          @creditLimit, @temporaryCredit, @creditPeriod, @balance, @priceLevel,
          @fixedDiscount, @paymentType, @blackListed, @suspend, @webSite,
          @disForEarlySettlement, @location, @showLocation, @taxGroupCode,
          @costCenter, @openBalance, @creditLimitRestrict, @creditPeriodRestrict,
          @outstadingRestrict, @pdChequeRestrict, @mainCustomerCode, @dob,
          @religious, @createdDate, @createdUser, @editedDate, @editedUser,
          @latitude, @longitude
        )
      `);

    if (cleanCreatedSalesman) {
      await new sql.Request(transaction)
        .input('customerCode', sql.NVarChar(15), customerCode)
        .input('createdSalesman', sql.NVarChar(15), cleanCreatedSalesman)
        .query(`
          UPDATE gen_customer
          SET CreatedSalesman = @createdSalesman
          WHERE CustomerCode = @customerCode
            AND LTRIM(RTRIM(ISNULL(CreatedSalesman, ''))) = ''
        `);
    }

    await transaction.commit();
    transactionStarted = false;
    invalidateCustomerCaches();

    const customer = {
      code: customerCode,
      name: cleanName.substring(0, 50),
      phone: cleanMobile,
      mobile: cleanMobile,
      address: address1.toString().substring(0, 70),
      address1: address1.toString().substring(0, 70),
      address2: address2.toString().substring(0, 70),
      address3: address3.toString().substring(0, 70),
      customerType: cleanCustomerType,
      customerId: cleanCustomerId,
      taxGroupCode: cleanTaxGroupCode,
      creditLimit: cleanCreditLimit,
      creditPeriod: cleanCreditPeriod,
      location: cleanLocation.substring(0, 50),
      costCenter: costCenter.toString().substring(0, 15),
      salesRepCode: cleanSalesRepCode,
      createdSalesman: cleanCreatedSalesman,
      contactPerson: contactPerson.toString().substring(0, 50),
      companyName: companyName.toString().substring(0, 50),
      latitude: parsedLatitude,
      longitude: parsedLongitude
    };

    console.log(`✅ Created customer ${customerCode} in gen_customer`);
    res.json({
      success: true,
      message: 'Customer saved successfully',
      customer
    });
  } catch (err) {
    try {
      if (transactionStarted && transaction) {
        await transaction.rollback();
      }
    } catch (rollbackError) {
      console.error('❌ Error rolling back customer save:', rollbackError);
    }

    console.error('❌ Error creating gen_customer:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to save customer',
      details: err.message
    });
  }
});

// Update existing customer in gen_customer
app.put('/api/customers/:customerCode', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const { customerCode } = req.params;
    const {
      customerName,
      location,
      mobile = '',
      customerId = '',
      address1 = '',
      address3 = '',
      customerType = 'Trade',
      taxGroupCode = '1',
      creditLimit = 0,
      creditPeriod = 0,
      salesRepCode = '',
      createdSalesman = '',
      editedUser = '',
      latitude,
      longitude
    } = req.body;

    const cleanCode = (customerCode || '').toString().trim();
    const cleanName = (customerName || '').toString().trim();
    let cleanLocation = (location || '').toString().trim();
    const cleanCustomerType = (customerType || 'Trade').toString().trim().substring(0, 10);
    const cleanCustomerId = (customerId || '').toString().trim().substring(0, 15);
    const cleanTaxGroupCode = (taxGroupCode || '1').toString().trim().substring(0, 15);
    const parsedCreditLimit = Number(creditLimit);
    const parsedCreditPeriod = Number(creditPeriod);
    const cleanCreditLimit = Number.isFinite(parsedCreditLimit) ? parsedCreditLimit : 0;
    const cleanCreditPeriod = Number.isFinite(parsedCreditPeriod) ? parsedCreditPeriod : 0;
    const cleanAddress3 = (address3 || '').toString().trim().substring(0, 70);
    const cleanMobile = mobile.toString().trim().substring(0, 50);
    const cleanCreatedSalesman = (
      createdSalesman ||
      salesRepCode ||
      ''
    ).toString().trim().substring(0, 15);
    const cleanSalesRepCode = (
      salesRepCode ||
      createdSalesman ||
      ''
    ).toString().trim().substring(0, 15);
    const hasLatitude = latitude !== undefined && latitude !== null && latitude !== '';
    const hasLongitude = longitude !== undefined && longitude !== null && longitude !== '';
    const parsedLatitude = hasLatitude ? Number(latitude) : null;
    const parsedLongitude = hasLongitude ? Number(longitude) : null;

    if (!cleanCode) {
      return res.status(400).json({
        success: false,
        error: 'Customer code is required'
      });
    }

    if (!cleanName) {
      return res.status(400).json({
        success: false,
        error: 'Customer name is required'
      });
    }

    if (!cleanCustomerId && !normalizeCustomerMobile(cleanMobile)) {
      return res.status(400).json({
        success: false,
        error: 'NIC or mobile number is required'
      });
    }

    if (
      (hasLatitude || hasLongitude) &&
      (!Number.isFinite(parsedLatitude) || !Number.isFinite(parsedLongitude))
    ) {
      return res.status(400).json({
        success: false,
        error: 'Latitude and longitude must both be valid numbers when provided'
      });
    }

    const existingCustomer = await findExistingCustomerByIdentity(pool.request(), {
      customerId: cleanCustomerId,
      mobile: cleanMobile,
      excludeCustomerCode: cleanCode,
    });
    if (existingCustomer) {
      return res.status(409).json({
        success: false,
        error: buildDuplicateCustomerMessage(existingCustomer),
        existingCustomer,
      });
    }

    const result = await pool.request()
      .input('customerCode', sql.NVarChar(15), cleanCode.substring(0, 15))
      .input('customerName', sql.NVarChar(50), cleanName.substring(0, 50))
      .input('payeeName', sql.NVarChar(50), cleanName.substring(0, 50))
      .input('address1', sql.NVarChar(70), address1.toString().substring(0, 70))
      .input('address3', sql.NVarChar(70), cleanAddress3)
      .input('mobile', sql.NVarChar(50), cleanMobile)
      .input('customerId', sql.NVarChar(15), cleanCustomerId)
      .input('customerType', sql.NVarChar(10), cleanCustomerType)
      .input('taxGroupCode', sql.NVarChar(15), cleanTaxGroupCode)
      .input('creditLimit', sql.Decimal(18, 0), cleanCreditLimit)
      .input('creditPeriod', sql.Decimal(18, 0), cleanCreditPeriod)
      .input('location', sql.NVarChar(50), cleanLocation.substring(0, 50))
      .input('salesRepCode', sql.NVarChar(15), cleanSalesRepCode)
      .input('createdSalesman', sql.NVarChar(15), cleanCreatedSalesman)
      .input('editedDate', sql.DateTime, new Date())
      .input('editedUser', sql.NChar(20), editedUser.toString().substring(0, 20))
      .input('latitude', sql.Decimal(10, 8), Number.isFinite(parsedLatitude) ? parsedLatitude : null)
      .input('longitude', sql.Decimal(11, 8), Number.isFinite(parsedLongitude) ? parsedLongitude : null)
      .query(`
        UPDATE gen_customer
        SET CustomerName = @customerName,
            PayeeName = @payeeName,
            Address1 = @address1,
            Address3 = @address3,
            Mobile = @mobile,
            CustomerId = @customerId,
            CustomerType = @customerType,
            TaxGroupCode = @taxGroupCode,
            CreditLimit = @creditLimit,
            CreditPeriod = @creditPeriod,
            Location = @location,
            SalesRepCode = @salesRepCode,
            CreatedSalesman = @createdSalesman,
            Edited_Date = @editedDate,
            Edited_User = @editedUser,
            Latitude = @latitude,
            Longitude = @longitude
        WHERE CustomerCode = @customerCode
          AND (Suspend = 0 OR Suspend IS NULL)
          AND (BlackListed = 0 OR BlackListed IS NULL)
      `);

    if (result.rowsAffected[0] === 0) {
      return res.status(404).json({
        success: false,
        error: 'Customer not found'
      });
    }

    const updatedRow = await pool.request()
      .input('customerCode', sql.NVarChar(15), cleanCode.substring(0, 15))
      .query(`
        SELECT ISNULL(CreatedSalesman, '') as createdSalesman
        FROM gen_customer
        WHERE CustomerCode = @customerCode
      `);
    const savedCreatedSalesman =
      updatedRow.recordset[0]?.createdSalesman || cleanCreatedSalesman;

    const customer = {
      code: cleanCode.substring(0, 15),
      name: cleanName.substring(0, 50),
      mobile: cleanMobile,
      address: address1.toString().substring(0, 70),
      address1: address1.toString().substring(0, 70),
      address3: cleanAddress3,
      customerType: cleanCustomerType,
      customerId: cleanCustomerId,
      taxGroupCode: cleanTaxGroupCode,
      creditLimit: cleanCreditLimit,
      creditPeriod: cleanCreditPeriod,
      location: cleanLocation.substring(0, 50),
      salesRepCode: cleanSalesRepCode,
      createdSalesman: savedCreatedSalesman,
      latitude: parsedLatitude,
      longitude: parsedLongitude
    };

    console.log(`✅ Updated customer ${cleanCode} in gen_customer`);
    res.json({
      success: true,
      message: 'Customer updated successfully',
      customer
    });
  } catch (err) {
    console.error('❌ Error updating gen_customer:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to update customer',
      details: err.message
    });
  }
});

// Daily rep leaderboard (ranked by sales order + quotation amounts)
app.get('/api/leaderboard/daily', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const dateParam = (req.query.date || '').toString().trim();
    let targetDate;

    if (dateParam) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(dateParam)) {
        return res.status(400).json({
          success: false,
          error: 'date must be YYYY-MM-DD'
        });
      }
      targetDate = dateParam;
    } else {
      const todayResult = await pool.request().query(`
        SELECT CONVERT(varchar(10), CAST(GETDATE() AS DATE), 120) AS today
      `);
      targetDate = todayResult.recordset[0]?.today;
    }

    const result = await pool.request()
      .input('targetDate', sql.Date, targetDate)
      .query(`
        WITH SalesOrders AS (
          SELECT
            LTRIM(RTRIM(ISNULL(SalesmanCode, ''))) AS repCode,
            COUNT(*) AS cnt,
            ISNULL(SUM(ISNULL(NetAmount, 0)), 0) AS amount
          FROM inv_invoiceheader
          WHERE Iid = 'SON'
            AND StatusId = 1
            AND CAST(DocumentDate AS DATE) = @targetDate
            AND LTRIM(RTRIM(ISNULL(SalesmanCode, ''))) <> ''
          GROUP BY SalesmanCode
        ),
        Quotations AS (
          SELECT
            LTRIM(RTRIM(ISNULL(SalesmanCode, ''))) AS repCode,
            COUNT(*) AS cnt,
            ISNULL(SUM(ISNULL(NetAmount, 0)), 0) AS amount
          FROM inv_invoiceheader
          WHERE Iid = 'QUO'
            AND StatusId = 1
            AND CAST(DocumentDate AS DATE) = @targetDate
            AND LTRIM(RTRIM(ISNULL(SalesmanCode, ''))) <> ''
          GROUP BY SalesmanCode
        ),
        AllReps AS (
          SELECT repCode FROM SalesOrders
          UNION
          SELECT repCode FROM Quotations
        )
        SELECT
          r.repCode AS salesmanCode,
          ISNULL(s.SalesmanName, r.repCode) AS salesmanName,
          ISNULL(so.cnt, 0) AS salesOrderCount,
          ISNULL(q.cnt, 0) AS quotationCount,
          ISNULL(so.amount, 0) AS salesOrderAmount,
          ISNULL(q.amount, 0) AS quotationAmount,
          ISNULL(so.amount, 0) + ISNULL(q.amount, 0) AS totalAmount
        FROM AllReps r
        LEFT JOIN gen_salesman s ON s.SalesmanCode = r.repCode
        LEFT JOIN SalesOrders so ON so.repCode = r.repCode
        LEFT JOIN Quotations q ON q.repCode = r.repCode
        ORDER BY
          totalAmount DESC,
          salesOrderAmount DESC,
          quotationAmount DESC,
          salesmanName ASC
      `);

    const entries = (result.recordset || []).map((row, index) => {
      const salesOrderAmount = Number(row.salesOrderAmount) || 0;
      const quotationAmount = Number(row.quotationAmount) || 0;
      const totalAmount = Number(row.totalAmount) || 0;
      return {
        rank: index + 1,
        salesmanCode: row.salesmanCode,
        salesmanName: row.salesmanName,
        salesOrderCount: row.salesOrderCount,
        quotationCount: row.quotationCount,
        salesOrderAmount,
        quotationAmount,
        totalAmount,
        // Keep totalScore as total amount for older clients
        totalScore: totalAmount,
      };
    });

    res.json({
      success: true,
      date: targetDate,
      entries
    });
  } catch (err) {
    console.error('❌ Error loading daily leaderboard:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load daily leaderboard',
      details: err.message
    });
  }
});

// Assign customers to a salesman
app.post('/api/admin/assign-customers', async (req, res) => {
  try {
    if (!pool) return res.status(503).json({ error: 'Database not connected' });
    
    const { salesmanCode, customerCodes } = req.body;
    if (!salesmanCode || !Array.isArray(customerCodes)) {
      return res.status(400).json({ error: 'Missing salesmanCode or customerCodes array' });
    }

    // First unassign all customers currently assigned to this salesman
    await pool.request()
      .input('salesmanCode', sql.NVarChar(50), salesmanCode)
      .query(`
        UPDATE gen_customer
        SET Assigned = NULL
        WHERE Assigned = @salesmanCode
      `);

    // Then assign the new ones
    if (customerCodes.length > 0) {
      const request = pool.request();
      request.input('salesmanCode', sql.NVarChar(50), salesmanCode);
      
      const parameters = [];
      customerCodes.forEach((code, index) => {
        const paramName = `c${index}`;
        request.input(paramName, sql.NVarChar(50), code);
        parameters.push(`@${paramName}`);
      });

      await request.query(`
        UPDATE gen_customer
        SET Assigned = @salesmanCode
        WHERE CustomerCode IN (${parameters.join(',')})
      `);
    }

    // Invalidate cached customer responses so that clients pull the latest assignments
    responseCache.clear();

    res.json({ success: true, message: 'Customers assigned successfully' });
  } catch (error) {
    console.error('❌ Error assigning customers:', error);
    res.status(500).json({ error: 'Failed to assign customers', details: error.message });
  }
});

// Get all salesmen from gen_salesman (for filters and admin lists)
app.get('/api/salesmen', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const result = await pool.request().query(`
      SELECT s.*, l.LocationDescription
      FROM gen_salesman s
      LEFT JOIN gen_location l ON s.Location = l.LocationCode
      WHERE (s.BlackListed = 0 OR s.BlackListed IS NULL)
        AND (s.Suspend = 0 OR s.Suspend IS NULL)
      ORDER BY s.SalesmanName, s.SalesmanCode
    `);

    res.json(result.recordset.map(sanitizeSalesmanRecord));
  } catch (err) {
    console.error('Error fetching salesmen:', err);
    res.status(500).json({ error: 'Failed to fetch salesmen' });
  }
});

// Search salesmen by code or name
app.get('/api/salesmen/search', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const { q } = req.query;
    const query = (q || '').toString().trim();

    if (!query) {
      return res.status(400).json({ error: 'Search query is required' });
    }

    const result = await pool.request()
      .input('query', sql.NVarChar(100), `%${query}%`)
      .query(`
        SELECT TOP 20
          SalesmanCode,
          SalesmanName,
          SalesmanType,
          Mobile,
          password,
          isAdmin,
          isSuper,
          BlackListed,
          Suspend,
          Created_Date
        FROM gen_salesman
        WHERE (SalesmanCode LIKE @query OR SalesmanName LIKE @query)
          AND (BlackListed = 0 OR BlackListed IS NULL)
          AND (Suspend = 0 OR Suspend IS NULL)
        ORDER BY SalesmanName
      `);

    res.json(result.recordset);
  } catch (err) {
    console.error('❌ Error searching salesmen:', err);
    res.status(500).json({
      error: 'Failed to search salesmen',
      details: err.message
    });
  }
});

// Create salesman in gen_salesman
app.post('/api/salesmen', async (req, res) => {
  let transaction;
  let transactionStarted = false;

  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const {
      salesmanName,
      password,
      mobile = '',
      salesmanType = 'sales',
      createdUser = '',
      isAdmin = false,
      costCenter = '000001'
    } = req.body;

    const cleanName = (salesmanName || '').toString().trim();
    const cleanPassword = (password || '').toString().trim();
    const adminFlag = isAdmin === true || isAdmin === 1 || isAdmin === '1';

    if (!cleanName || !cleanPassword) {
      return res.status(400).json({
        success: false,
        error: 'Salesman name and password are required'
      });
    }

    transaction = new sql.Transaction(pool);
    await transaction.begin(sql.ISOLATION_LEVEL.SERIALIZABLE);
    transactionStarted = true;

    const codeResult = await new sql.Request(transaction).query(`
      SELECT MAX(CAST(SUBSTRING(SalesmanCode, 3, 12) AS int)) as maxNumber
      FROM gen_salesman WITH (UPDLOCK, HOLDLOCK)
      WHERE SalesmanCode LIKE 'SM[0-9]%'
        AND SUBSTRING(SalesmanCode, 3, 12) NOT LIKE '%[^0-9]%'
    `);

    const nextNumber = (codeResult.recordset[0]?.maxNumber || 0) + 1;
    const salesmanCode = `SM${nextNumber.toString().padStart(6, '0')}`;
    const finalType = adminFlag ? 'admin' : salesmanType.toString();

    await new sql.Request(transaction)
      .input('salesmanCode', sql.NVarChar(15), salesmanCode)
      .input('salesmanName', sql.NVarChar(50), cleanName.substring(0, 50))
      .input('salesmanTitle', sql.NVarChar(5), '')
      .input('salesmanType', sql.NVarChar(10), finalType.substring(0, 10))
      .input('salesmanId', sql.NVarChar(10), '')
      .input('areaCode', sql.NVarChar(15), '')
      .input('territoryCode', sql.NVarChar(15), '')
      .input('rootCode', sql.NVarChar(15), '')
      .input('address1', sql.NVarChar(70), '')
      .input('address2', sql.NVarChar(70), '')
      .input('address3', sql.NVarChar(70), '')
      .input('tno', sql.NVarChar(50), '')
      .input('mobile', sql.NVarChar(50), mobile.toString().substring(0, 50))
      .input('fax', sql.NVarChar(50), '')
      .input('email', sql.NVarChar(50), '')
      .input('creditLimit', sql.Decimal(18, 0), 0)
      .input('temporaryCredit', sql.Decimal(18, 0), 0)
      .input('creditPeriod', sql.Decimal(18, 0), 0)
      .input('discountLevel', sql.NChar(20), '')
      .input('blackListed', sql.Int, 0)
      .input('suspend', sql.Int, 0)
      .input('webSite', sql.NChar(50), '')
      .input('location', sql.NChar(10), '')
      .input('showLocation', sql.Int, 0)
      .input('createdDate', sql.DateTime, new Date())
      .input('createdUser', sql.NChar(20), createdUser.toString().substring(0, 20))
      .input('editedDate', sql.DateTime, null)
      .input('editedUser', sql.NChar(20), '')
      .input('commissionPolicy', sql.NVarChar(10), '')
      .input('costCenter', sql.NVarChar(15), costCenter.toString().substring(0, 15))
      .input('salesmanGroup', sql.NVarChar(10), '')
      .input('password', sql.NVarChar(50), cleanPassword.substring(0, 50))
      .input('isAdmin', sql.Bit, adminFlag)
      .input('isSuper', sql.Bit, false)
      .query(`
        INSERT INTO gen_salesman (
          SalesmanCode, SalesmanName, SalesmanTitle, SalesmanType, SalesmanId,
          AreaCode, TerritoryCode, RootCode, Address1, Address2, Address3,
          Tno, Mobile, Fax, Email, CreditLimit, TemporaryCredit, CreditPeriod,
          DiscountLevel, BlackListed, Suspend, WebSite, Location, ShowLocation,
          Created_Date, Created_User, Edited_Date, Edited_User,
          CommissionPolicy, CostCenter, SalesmanGroup, password, isAdmin, isSuper
        ) VALUES (
          @salesmanCode, @salesmanName, @salesmanTitle, @salesmanType, @salesmanId,
          @areaCode, @territoryCode, @rootCode, @address1, @address2, @address3,
          @tno, @mobile, @fax, @email, @creditLimit, @temporaryCredit, @creditPeriod,
          @discountLevel, @blackListed, @suspend, @webSite, @location, @showLocation,
          @createdDate, @createdUser, @editedDate, @editedUser,
          @commissionPolicy, @costCenter, @salesmanGroup, @password, @isAdmin, @isSuper
        )
      `);

    await transaction.commit();
    transactionStarted = false;

    const salesman = {
      SalesmanCode: salesmanCode,
      SalesmanName: cleanName.substring(0, 50),
      SalesmanType: finalType.substring(0, 10),
      Mobile: mobile.toString().substring(0, 50),
      Email: '',
      Location: '',
      isAdmin: adminFlag,
      isSuper: false
    };

    console.log(`✅ Created salesman ${salesmanCode} in gen_salesman`);
    res.json({
      success: true,
      message: 'Salesman saved successfully',
      salesman
    });
  } catch (err) {
    try {
      if (transactionStarted && transaction) {
        await transaction.rollback();
      }
    } catch (rollbackError) {
      console.error('❌ Error rolling back salesman save:', rollbackError);
    }

    console.error('❌ Error creating gen_salesman:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to save salesman',
      details: err.message
    });
  }
});

// Update salesman access level
app.put('/api/salesmen/:salesmanCode/access', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const { salesmanCode } = req.params;
    const { accessLevel = 'sales', editedUser = '' } = req.body;
    const cleanCode = (salesmanCode || '').toString().trim();
    const cleanAccessLevel = (accessLevel || '').toString().trim().toLowerCase();

    if (!cleanCode) {
      return res.status(400).json({ success: false, error: 'Salesman code is required' });
    }

    if (!['sales', 'admin'].includes(cleanAccessLevel)) {
      return res.status(400).json({
        success: false,
        error: 'Access level must be Salesman or Admin'
      });
    }

    const isAdmin = cleanAccessLevel === 'admin';
    const salesmanType = isAdmin ? 'admin' : 'sales';

    const result = await pool.request()
      .input('salesmanCode', sql.NVarChar(15), cleanCode)
      .input('salesmanType', sql.NVarChar(10), salesmanType)
      .input('isAdmin', sql.Bit, isAdmin)
      .input('isSuper', sql.Bit, false)
      .input('editedDate', sql.DateTime, new Date())
      .input('editedUser', sql.NChar(20), editedUser.toString().substring(0, 20))
      .query(`
        UPDATE gen_salesman
        SET SalesmanType = @salesmanType,
            isAdmin = @isAdmin,
            isSuper = @isSuper,
            Edited_Date = @editedDate,
            Edited_User = @editedUser
        WHERE SalesmanCode = @salesmanCode
          AND (BlackListed = 0 OR BlackListed IS NULL)
          AND (Suspend = 0 OR Suspend IS NULL)
      `);

    if (result.rowsAffected[0] === 0) {
      return res.status(404).json({
        success: false,
        error: 'Salesman not found'
      });
    }

    res.json({
      success: true,
      message: 'Salesman access level updated successfully',
      salesman: {
        SalesmanCode: cleanCode,
        SalesmanType: salesmanType,
        isAdmin,
        isSuper: false
      }
    });
  } catch (err) {
    console.error('❌ Error updating salesman access level:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to update salesman access level',
      details: err.message
    });
  }
});

const DEFAULT_USE_RIGHTS = {
  CanSalesOrder: true,
  CanInvoice: true,
  CanQuotation: true,
  CanCRN: true,
  CanMySalesHistory: true,
  CanCustomerCreate: true,
  CanCustomerLocations: true,
  CanLeaderboard: true,
  CanStockReports: false,
  CanReceipts: false,
  CanAdminSalesmanLocationHistory: true,
  CanAdminUserCreation: true,
  CanAdminSalesAndHistory: true,
  CanAdminLocationTracking: true,
  CanAdminCurrentSale: true,
};

function bitToBool(value, fallback = true) {
  if (value === undefined || value === null) return fallback;
  return value === true || value === 1 || value === '1';
}

function mapUseRightsRow(row) {
  if (!row) return { ...DEFAULT_USE_RIGHTS };
  return {
    CanSalesOrder: bitToBool(row.CanSalesOrder, DEFAULT_USE_RIGHTS.CanSalesOrder),
    CanInvoice: bitToBool(row.CanInvoice, DEFAULT_USE_RIGHTS.CanInvoice),
    CanQuotation: bitToBool(row.CanQuotation, DEFAULT_USE_RIGHTS.CanQuotation),
    CanCRN: bitToBool(row.CanCRN, DEFAULT_USE_RIGHTS.CanCRN),
    CanMySalesHistory: bitToBool(row.CanMySalesHistory, DEFAULT_USE_RIGHTS.CanMySalesHistory),
    CanCustomerCreate: bitToBool(row.CanCustomerCreate, DEFAULT_USE_RIGHTS.CanCustomerCreate),
    CanCustomerLocations: bitToBool(row.CanCustomerLocations, DEFAULT_USE_RIGHTS.CanCustomerLocations),
    CanLeaderboard: bitToBool(row.CanLeaderboard, DEFAULT_USE_RIGHTS.CanLeaderboard),
    CanStockReports: bitToBool(row.CanStockReports, DEFAULT_USE_RIGHTS.CanStockReports),
    CanReceipts: bitToBool(row.CanReceipts, DEFAULT_USE_RIGHTS.CanReceipts),
    CanAdminSalesmanLocationHistory: bitToBool(
      row.CanAdminSalesmanLocationHistory,
      DEFAULT_USE_RIGHTS.CanAdminSalesmanLocationHistory,
    ),
    CanAdminUserCreation: bitToBool(
      row.CanAdminUserCreation,
      DEFAULT_USE_RIGHTS.CanAdminUserCreation,
    ),
    CanAdminSalesAndHistory: bitToBool(
      row.CanAdminSalesAndHistory,
      DEFAULT_USE_RIGHTS.CanAdminSalesAndHistory,
    ),
    CanAdminLocationTracking: bitToBool(
      row.CanAdminLocationTracking,
      DEFAULT_USE_RIGHTS.CanAdminLocationTracking,
    ),
    CanAdminCurrentSale: bitToBool(
      row.CanAdminCurrentSale,
      DEFAULT_USE_RIGHTS.CanAdminCurrentSale,
    ),
  };
}

function buildUseRightsFromIncoming(incoming) {
  return {
    CanSalesOrder: bitToBool(incoming.CanSalesOrder, DEFAULT_USE_RIGHTS.CanSalesOrder),
    CanInvoice: bitToBool(incoming.CanInvoice, DEFAULT_USE_RIGHTS.CanInvoice),
    CanQuotation: bitToBool(incoming.CanQuotation, DEFAULT_USE_RIGHTS.CanQuotation),
    CanCRN: bitToBool(incoming.CanCRN, DEFAULT_USE_RIGHTS.CanCRN),
    CanMySalesHistory: bitToBool(incoming.CanMySalesHistory, DEFAULT_USE_RIGHTS.CanMySalesHistory),
    CanCustomerCreate: bitToBool(incoming.CanCustomerCreate, DEFAULT_USE_RIGHTS.CanCustomerCreate),
    CanCustomerLocations: bitToBool(incoming.CanCustomerLocations, DEFAULT_USE_RIGHTS.CanCustomerLocations),
    CanLeaderboard: bitToBool(incoming.CanLeaderboard, DEFAULT_USE_RIGHTS.CanLeaderboard),
    CanStockReports: bitToBool(incoming.CanStockReports, DEFAULT_USE_RIGHTS.CanStockReports),
    CanReceipts: bitToBool(incoming.CanReceipts, DEFAULT_USE_RIGHTS.CanReceipts),
    CanAdminSalesmanLocationHistory: bitToBool(
      incoming.CanAdminSalesmanLocationHistory,
      DEFAULT_USE_RIGHTS.CanAdminSalesmanLocationHistory,
    ),
    CanAdminUserCreation: bitToBool(
      incoming.CanAdminUserCreation,
      DEFAULT_USE_RIGHTS.CanAdminUserCreation,
    ),
    CanAdminSalesAndHistory: bitToBool(
      incoming.CanAdminSalesAndHistory,
      DEFAULT_USE_RIGHTS.CanAdminSalesAndHistory,
    ),
    CanAdminLocationTracking: bitToBool(
      incoming.CanAdminLocationTracking,
      DEFAULT_USE_RIGHTS.CanAdminLocationTracking,
    ),
    CanAdminCurrentSale: bitToBool(
      incoming.CanAdminCurrentSale,
      DEFAULT_USE_RIGHTS.CanAdminCurrentSale,
    ),
  };
}

// Get salesman section use-rights
app.get('/api/salesmen/:salesmanCode/use-rights', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const cleanCode = (req.params.salesmanCode || '').toString().trim();
    if (!cleanCode) {
      return res.status(400).json({ success: false, error: 'Salesman code is required' });
    }

    const result = await pool.request()
      .input('salesmanCode', sql.NVarChar(15), cleanCode)
      .query(`
        SELECT *
        FROM gen_salesmanUseRights
        WHERE SalesmanCode = @salesmanCode
      `);

    const rights = mapUseRightsRow(result.recordset[0]);
    res.json({
      success: true,
      salesmanCode: cleanCode,
      rights,
      isDefault: result.recordset.length === 0,
    });
  } catch (err) {
    console.error('❌ Error loading salesman use rights:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load salesman use rights',
      details: err.message,
    });
  }
});

// Upsert salesman section use-rights
app.put('/api/salesmen/:salesmanCode/use-rights', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const cleanCode = (req.params.salesmanCode || '').toString().trim();
    const editedUser = (req.body?.editedUser || '').toString().substring(0, 50);
    const incoming = req.body?.rights && typeof req.body.rights === 'object'
      ? req.body.rights
      : req.body || {};

    if (!cleanCode) {
      return res.status(400).json({ success: false, error: 'Salesman code is required' });
    }

    const salesmanExists = await pool.request()
      .input('salesmanCode', sql.NVarChar(15), cleanCode)
      .query(`
        SELECT TOP 1 SalesmanCode
        FROM gen_salesman
        WHERE SalesmanCode = @salesmanCode
          AND (BlackListed = 0 OR BlackListed IS NULL)
          AND (Suspend = 0 OR Suspend IS NULL)
      `);

    if (salesmanExists.recordset.length === 0) {
      return res.status(404).json({ success: false, error: 'Salesman not found' });
    }

    const rights = buildUseRightsFromIncoming(incoming);

    await pool.request()
      .input('salesmanCode', sql.NVarChar(15), cleanCode)
      .input('CanSalesOrder', sql.Bit, rights.CanSalesOrder)
      .input('CanInvoice', sql.Bit, rights.CanInvoice)
      .input('CanQuotation', sql.Bit, rights.CanQuotation)
      .input('CanCRN', sql.Bit, rights.CanCRN)
      .input('CanMySalesHistory', sql.Bit, rights.CanMySalesHistory)
      .input('CanCustomerCreate', sql.Bit, rights.CanCustomerCreate)
      .input('CanCustomerLocations', sql.Bit, rights.CanCustomerLocations)
      .input('CanLeaderboard', sql.Bit, rights.CanLeaderboard)
      .input('CanStockReports', sql.Bit, rights.CanStockReports)
      .input('CanReceipts', sql.Bit, rights.CanReceipts)
      .input('CanAdminSalesmanLocationHistory', sql.Bit, rights.CanAdminSalesmanLocationHistory)
      .input('CanAdminUserCreation', sql.Bit, rights.CanAdminUserCreation)
      .input('CanAdminSalesAndHistory', sql.Bit, rights.CanAdminSalesAndHistory)
      .input('CanAdminLocationTracking', sql.Bit, rights.CanAdminLocationTracking)
      .input('CanAdminCurrentSale', sql.Bit, rights.CanAdminCurrentSale)
      .input('editedUser', sql.NVarChar(50), editedUser)
      .input('editedDate', sql.DateTime2, new Date())
      .query(`
        MERGE gen_salesmanUseRights AS target
        USING (SELECT @salesmanCode AS SalesmanCode) AS source
          ON target.SalesmanCode = source.SalesmanCode
        WHEN MATCHED THEN
          UPDATE SET
            CanSalesOrder = @CanSalesOrder,
            CanInvoice = @CanInvoice,
            CanQuotation = @CanQuotation,
            CanCRN = @CanCRN,
            CanMySalesHistory = @CanMySalesHistory,
            CanCustomerCreate = @CanCustomerCreate,
            CanCustomerLocations = @CanCustomerLocations,
            CanLeaderboard = @CanLeaderboard,
            CanStockReports = @CanStockReports,
            CanReceipts = @CanReceipts,
            CanAdminSalesmanLocationHistory = @CanAdminSalesmanLocationHistory,
            CanAdminUserCreation = @CanAdminUserCreation,
            CanAdminSalesAndHistory = @CanAdminSalesAndHistory,
            CanAdminLocationTracking = @CanAdminLocationTracking,
            CanAdminCurrentSale = @CanAdminCurrentSale,
            Edited_User = @editedUser,
            Edited_Date = @editedDate
        WHEN NOT MATCHED THEN
          INSERT (
            SalesmanCode,
            CanSalesOrder,
            CanInvoice,
            CanQuotation,
            CanCRN,
            CanMySalesHistory,
            CanCustomerCreate,
            CanCustomerLocations,
            CanLeaderboard,
            CanStockReports,
            CanReceipts,
            CanAdminSalesmanLocationHistory,
            CanAdminUserCreation,
            CanAdminSalesAndHistory,
            CanAdminLocationTracking,
            CanAdminCurrentSale,
            Created_User,
            Created_Date,
            Edited_User,
            Edited_Date
          )
          VALUES (
            @salesmanCode,
            @CanSalesOrder,
            @CanInvoice,
            @CanQuotation,
            @CanCRN,
            @CanMySalesHistory,
            @CanCustomerCreate,
            @CanCustomerLocations,
            @CanLeaderboard,
            @CanStockReports,
            @CanReceipts,
            @CanAdminSalesmanLocationHistory,
            @CanAdminUserCreation,
            @CanAdminSalesAndHistory,
            @CanAdminLocationTracking,
            @CanAdminCurrentSale,
            @editedUser,
            @editedDate,
            @editedUser,
            @editedDate
          );
      `);

    res.json({
      success: true,
      message: 'User rights updated successfully',
      salesmanCode: cleanCode,
      rights,
    });
  } catch (err) {
    console.error('❌ Error updating salesman use rights:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to update salesman use rights',
      details: err.message,
    });
  }
});

// Get all locations
app.get('/api/locations', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    console.log('🔄 Fetching locations from gen_location...');
    const result = await pool.request().query(`
      SELECT 
        LocationCode,
        LocationDescription,
        CompanyCode,
        Address1,
        Address2,
        Address3,
        Tno,
        Fax,
        Email
      FROM gen_location
      ORDER BY LocationCode
    `);
    
    console.log(`✅ Loaded ${result.recordset.length} locations from database`);
    res.json(result.recordset);
  } catch (err) {
    console.error('Error fetching locations:', err);
    res.status(500).json({ error: 'Failed to fetch locations' });
  }
});

// Search products
app.get('/api/products/search', async (req, res) => {
  try {
    const { q } = req.query;
    if (!q) {
      return res.status(400).json({ error: 'Search query is required' });
    }
    
    const productSelect = await getInvoiceProductSelectClause();
    const result = await pool.request()
      .input('searchTerm', sql.NVarChar, `%${q}%`)
      .query(`
        SELECT TOP 50 ${productSelect}
        FROM inv_productmaster 
        WHERE (ProductName LIKE @searchTerm OR ProductCode LIKE @searchTerm)
        AND (LockProduct = 0 OR LockProduct IS NULL)
        ORDER BY ProductName
      `);
    res.json(result.recordset);
  } catch (err) {
    console.error('Error searching products:', err);
    res.status(500).json({ error: 'Search failed' });
  }
});

// ==================== SUSPEND ORDERS ====================

// Get all suspend orders
app.get('/api/suspend-orders', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const result = await pool.request().query(`
      SELECT * FROM inv_suspend 
      ORDER BY id DESC
    `);
    res.json(result.recordset);
  } catch (err) {
    console.error('Error fetching suspend orders:', err);
    res.status(500).json({ error: 'Failed to fetch suspend orders' });
  }
});

// Get suspend orders by table
app.get('/api/suspend-orders/table/:tableNumber', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const { tableNumber } = req.params;
    const result = await pool.request()
      .input('tableNumber', sql.NVarChar, tableNumber)
      .query(`
        SELECT * FROM inv_suspend 
        WHERE [Table] = @tableNumber
        ORDER BY id DESC
      `);
    res.json(result.recordset);
  } catch (err) {
    console.error('Error fetching suspend orders by table:', err);
    res.status(500).json({ error: 'Failed to fetch suspend orders' });
  }
});

// Create suspend order (add item to cart)
app.post('/api/suspend-orders', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    // Extract fields from request body
    const {
      id, // Can be provided from Flutter UI or auto-generated by database
      ProductCode: productCode,
      ProductDescription: productDescription,
      Unit: unit,
      PackSize: packSize,
      FreeQty: freeQty,
      CostPrice: costPrice,
      UnitPrice: unitPrice,
      WholeSalePrice: wholeSalePrice,
      Qty: qty,
      DiscPer: discPer,
      DiscAmount: discAmount,
      Amount: amount,
      Iid: iid,
      LocaCode: locaCode,
      BatchNo: batchNo,
      StockLoca: stockLoca,
      Tax: tax,
      RowIdx: rowIdx,
      SerialNo: serialNo,
      WarrantyPeriod: warrantyPeriod,
      PeriodDays: periodDays,
      ExpiryDate: expiryDate,
      ReceiptNo: receiptNo,
      SalesMan: salesMan,
      Customer: customer,
      Table: table,
      Chair: chair,
      KotPrint: kotPrint
    } = req.body;
    
    console.log('📋 Request body received:', {
      productCode,
      productDescription,
      unitPrice,
      qty,
      amount,
      salesMan,
      table,
      locaCode,
      batchNo
    });
    
    // Validate and set BatchNo - only allow: "DineIn", "RoomService", or "Takeaway"
    const validBatchNumbers = ['DineIn', 'RoomService', 'Takeaway'];
    let finalBatchNo = batchNo;
    
    if (!finalBatchNo || !validBatchNumbers.includes(finalBatchNo)) {
      finalBatchNo = 'DineIn'; // Default to DineIn
      console.log(`⚠️  Invalid or missing BatchNo. Using default: ${finalBatchNo}`);
    } else {
      console.log(`✅ Valid BatchNo: ${finalBatchNo}`);
    }
    
    // Get location code from gen_salesman if not provided
    let finalLocaCode = locaCode;
    if (!finalLocaCode && salesMan) {
      try {
        const salesmanResult = await pool.request()
          .input('salesmanCode', sql.NVarChar, salesMan)
          .query('SELECT Location FROM gen_salesman WHERE SalesmanCode = @salesmanCode');
        
        if (salesmanResult.recordset.length > 0) {
          finalLocaCode = salesmanResult.recordset[0].Location;
          console.log(`✅ Retrieved location code '${finalLocaCode}' from salesman ${salesMan}`);
        }
      } catch (err) {
        console.error('Error fetching salesman location:', err);
      }
    }
    
    // Fallback to '01' if still no location code
    if (!finalLocaCode) {
      finalLocaCode = '01';
      console.log(`⚠️  No location code found, using default: ${finalLocaCode}`);
    }
    
    // ID column is NOT an identity column - must always be provided
    if (!id) {
      return res.status(400).json({ 
        success: false, 
        error: 'ID is required',
        message: 'The id field must be provided from Flutter UI. Use the # number from your interface.'
      });
    }
    
    console.log(`📋 Using provided ID: ${id}`);
    
    // Don't generate ReceiptNo when adding items to cart
    // Receipt number will be assigned only when order is confirmed
    let finalReceiptNo = receiptNo || null;
    console.log(`📋 ReceiptNo for cart item: ${finalReceiptNo || 'NULL (will be assigned on order confirmation)'}`);

    
    // ALWAYS INSERT NEW ROWS - NEVER UPDATE
    // Even if same product is ordered multiple times, each order gets its own row
    // This preserves order history and allows tracking individual items separately
    
    // KotPrint Logic:
    // - New items (adding to cart): KotPrint = 1 (needs to be printed in kitchen)
    // - Use provided kotPrint value or default to 1
    let finalKotPrint = 1; // Default for new items - MUST be printed
    
    if (kotPrint !== undefined && kotPrint !== null) {
      finalKotPrint = kotPrint ? 1 : 0;
      console.log(`✅ New item ${id} for table ${table} - using provided kotPrint = ${finalKotPrint}`);
    } else {
      finalKotPrint = 1;
      console.log(`✅ New item ${id} for table ${table} - defaulting to kotPrint = 1 (will be sent to kitchen)`);
    }
    
    // ALWAYS INSERT - Each order is a new row
    // Frontend is responsible for providing unique IDs
    try {
      await pool.request()
        .input('id', sql.Int, id)
        .input('productCode', sql.NVarChar, productCode)
        .input('productDescription', sql.NVarChar, productDescription)
        .input('unitPrice', sql.Decimal(18, 2), unitPrice)
        .input('qty', sql.Decimal(18, 2), qty)
        .input('amount', sql.Decimal(18, 2), amount)
        .input('salesMan', sql.NVarChar, salesMan)
        .input('table', sql.NVarChar, table)
        .input('chair', sql.NVarChar, chair || null)
        .input('freeQty', sql.Decimal(18, 2), freeQty || 0)
        .input('discPer', sql.Decimal(18, 2), discPer || 0)
        .input('discAmount', sql.Decimal(18, 2), discAmount || 0)
        .input('locaCode', sql.NVarChar, finalLocaCode)
        .input('batchNo', sql.NVarChar, finalBatchNo)
        .input('serialNo', sql.NVarChar, serialNo || '')
        .input('customer', sql.NVarChar, '....')
        .input('receiptNo', sql.NVarChar, finalReceiptNo)
        .input('kotPrint', sql.Bit, finalKotPrint)
        .query(`
          INSERT INTO inv_suspend (
            id, ProductCode, ProductDescription, UnitPrice, Qty, Amount, SalesMan, [Table], Chair,
            FreeQty, DiscPer, DiscAmount, LocaCode, BatchNo, SerialNo, Customer, ReceiptNo, KotPrint
          ) VALUES (
            @id, @productCode, @productDescription, @unitPrice, @qty, @amount, @salesMan, @table, @chair,
            @freeQty, @discPer, @discAmount, @locaCode, @batchNo, @serialNo, @customer, @receiptNo, @kotPrint
          )
        `);
      
      console.log(`✅ Inserted new row: ID ${id} for table ${table} (Product: ${productCode})`);
    } catch (insertError) {
      // Check if it's a duplicate key error
      if (insertError.number === 2627 || insertError.number === 2601) {
        console.error(`❌ Duplicate ID ${id} for table ${table} - Frontend should provide unique IDs`);
        throw new Error(`Duplicate ID ${id} already exists for table ${table}. Please use a different ID.`);
      }
      throw insertError;
    }
    
    const newId = id;
    console.log(`✅ Created suspend order item with ID: ${newId}`);
    
    // Broadcast the change to connected clients
    broadcastDataChange('suspend_orders', {
      action: 'created',
      id: newId,
      table: table
    });
    
    res.json({ success: true, id: newId });
  } catch (err) {
    console.error('Error creating suspend order:', err);
    console.error('Error details:', err.message);
    res.status(500).json({ error: 'Failed to create suspend order', details: err.message });
  }
});

// Update suspend order
app.put('/api/suspend-orders/:id', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const { id } = req.params;
    const {
      productCode,
      productDescription,
      unit,
      packSize,
      freeQty,
      costPrice,
      unitPrice,
      wholeSalePrice,
      qty,
      discPer,
      discAmount,
      amount,
      iid,
      locaCode,
      batchNo,
      stockLoca,
      tax,
      rowIdx,
      serialNo,
      warrantyPeriod,
      periodDays,
      expiryDate,
      receiptNo,
      salesMan,
      customer,
      table,
      chair,
      kotPrint
    } = req.body;
    
    await pool.request()
      .input('id', sql.Int, id)
      .input('productCode', sql.NVarChar, productCode)
      .input('productDescription', sql.NVarChar, productDescription)
      .input('unit', sql.NVarChar, unit)
      .input('packSize', sql.Decimal(18, 2), packSize)
      .input('freeQty', sql.Decimal(18, 2), freeQty)
      .input('costPrice', sql.Decimal(18, 2), costPrice)
      .input('unitPrice', sql.Decimal(18, 2), unitPrice)
      .input('wholeSalePrice', sql.Decimal(18, 2), wholeSalePrice)
      .input('qty', sql.Decimal(18, 2), qty)
      .input('discPer', sql.Decimal(18, 2), discPer)
      .input('discAmount', sql.Decimal(18, 2), discAmount)
      .input('amount', sql.Decimal(18, 2), amount)
      .input('iid', sql.NVarChar, iid)
      .input('locaCode', sql.NVarChar, locaCode)
      .input('batchNo', sql.NVarChar, batchNo)
      .input('stockLoca', sql.NVarChar, stockLoca)
      .input('tax', sql.Decimal(18, 2), tax)
      .input('rowIdx', sql.Int, rowIdx)
      .input('serialNo', sql.NVarChar, serialNo)
      .input('warrantyPeriod', sql.Int, warrantyPeriod)
      .input('periodDays', sql.Int, periodDays)
      .input('expiryDate', sql.DateTime, expiryDate)
      .input('receiptNo', sql.NVarChar, receiptNo)
      .input('salesMan', sql.NVarChar, salesMan)
      .input('customer', sql.NVarChar, customer)
      .input('table', sql.NVarChar, table)
      .input('chair', sql.NVarChar, chair)
      .input('kotPrint', sql.Bit, kotPrint)
      .query(`
        UPDATE inv_suspend SET
          ProductCode = @productCode,
          ProductDescription = @productDescription,
          Unit = @unit,
          PackSize = @packSize,
          FreeQty = @freeQty,
          CostPrice = @costPrice,
          UnitPrice = @unitPrice,
          WholeSalePrice = @wholeSalePrice,
          Qty = @qty,
          DiscPer = @discPer,
          DiscAmount = @discAmount,
          Amount = @amount,
          Iid = @iid,
          LocaCode = @locaCode,
          BatchNo = @batchNo,
          StockLoca = @stockLoca,
          Tax = @tax,
          RowIdx = @rowIdx,
          SerialNo = @serialNo,
          WarrantyPeriod = @warrantyPeriod,
          PeriodDays = @periodDays,
          ExpiryDate = @expiryDate,
          ReceiptNo = @receiptNo,
          SalesMan = @salesMan,
          Customer = @customer,
          [Table] = @table,
          Chair = @chair,
          KotPrint = @kotPrint
        WHERE id = @id
      `);
    
    console.log(`✅ Updated suspend order with ID: ${id}`);
    
    // Broadcast the change to connected clients
    broadcastDataChange('suspend_orders', {
      action: 'updated',
      id: id
    });
    
    res.json({ success: true });
  } catch (err) {
    console.error('Error updating suspend order:', err);
    res.status(500).json({ error: 'Failed to update suspend order' });
  }
});

// Delete suspend order
app.delete('/api/suspend-orders/:id', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const { id } = req.params;
    
    await pool.request()
      .input('id', sql.Int, id)
      .query('DELETE FROM inv_suspend WHERE id = @id');
    
    console.log(`✅ Deleted suspend order with ID: ${id}`);
    
    // Broadcast the change to connected clients
    broadcastDataChange('suspend_orders', {
      action: 'deleted',
      id: id
    });
    
    res.json({ success: true });
  } catch (err) {
    console.error('Error deleting suspend order:', err);
    res.status(500).json({ error: 'Failed to delete suspend order' });
  }
});

// Get receipt number for order (combines unit and ReceiptNo from sysconfig)
app.get('/api/orders/generate-receipt/:tableNumber', async (req, res) => {
  try {
    if (!pool) {
      console.error('❌ Database not connected');
      return res.status(503).json({ 
        success: false,
        error: 'Database not connected' 
      });
    }
    
    const { tableNumber } = req.params;
    console.log(`📋 Generating receipt number for table/room: ${tableNumber}`);
    
    // Get both Unit and ReceiptNo from sysconfig (with NOLOCK to read latest value)
    const sysconfigResult = await pool.request().query(`SELECT Unit, ReceiptNo FROM sysconfig WITH (NOLOCK)`);
    
    if (sysconfigResult.recordset.length === 0) {
      console.error('❌ Sysconfig not found in database');
      return res.status(404).json({ 
        success: false,
        error: 'Sysconfig not found' 
      });
    }
    
    // Get unit from sysconfig and convert to string
    const unitValue = sysconfigResult.recordset[0].Unit;
    const unit = unitValue !== null && unitValue !== undefined ? unitValue.toString() : '1';
    console.log(`📋 Unit from sysconfig: ${unit} (raw value: ${unitValue}, type: ${typeof unitValue})`);
    
    // Get ReceiptNo counter from sysconfig
    const counter = parseInt(sysconfigResult.recordset[0].ReceiptNo) || 1;
    const receiptCounter = counter.toString().padStart(8, '0');
    console.log(`📋 ReceiptNo from sysconfig: ${receiptCounter} (raw value: ${sysconfigResult.recordset[0].ReceiptNo})`);
    
    // Combine unit + receiptCounter (e.g., "1" + "00000001" = "100000001")
    const finalReceiptNo = unit + receiptCounter;
    console.log(`✅ Generated receipt number: ${finalReceiptNo}`);
    
    // Increment sysconfig counter for next order
    const nextCounter = counter + 1;
    await pool.request()
      .input('newReceiptNo', sql.Int, nextCounter)
      .query('UPDATE sysconfig SET ReceiptNo = @newReceiptNo');
    
    console.log(`✅ Incremented sysconfig ReceiptNo from ${counter} to ${nextCounter}`);
    
    res.json({ 
      success: true, 
      receiptNo: finalReceiptNo,
      unit: unit,
      counter: receiptCounter
    });
  } catch (err) {
    console.error('❌ Error generating receipt number:', err);
    console.error('❌ Error details:', err.message);
    res.status(500).json({ 
      success: false,
      error: 'Failed to generate receipt number',
      details: err.message
    });
  }
});

// Confirm order (move from suspend to final order)
app.post('/api/orders/confirm/:tableNumber', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const { tableNumber } = req.params;
    const { receiptNo, salesMan } = req.body;
    
    // Get all suspend orders for this table
    const suspendOrders = await pool.request()
      .input('tableNumber', sql.NVarChar, tableNumber)
      .query(`
        SELECT * FROM inv_suspend 
        WHERE [Table] = @tableNumber
      `);
    
    if (suspendOrders.recordset.length === 0) {
      return res.status(404).json({ error: 'No pending orders found for this table' });
    }
    
    // Get and increment the order counter
    let orderNumber;
    try {
      // Try to get current counter value
      const counterResult = await pool.request().query(`
        SELECT counter_value FROM order_counter WHERE counter_name = 'daily_orders'
      `);
      
      if (counterResult.recordset.length > 0) {
        // Increment existing counter
        orderNumber = counterResult.recordset[0].counter_value + 1;
        await pool.request()
          .input('newValue', sql.Int, orderNumber)
          .query(`
            UPDATE order_counter 
            SET counter_value = @newValue, last_updated = GETDATE()
            WHERE counter_name = 'daily_orders'
          `);
      } else {
        // Create counter table and initialize
        orderNumber = 1;
        await pool.request().query(`
          IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='order_counter' AND xtype='U')
          CREATE TABLE order_counter (
            counter_name NVARCHAR(50) PRIMARY KEY,
            counter_value INT NOT NULL,
            last_updated DATETIME DEFAULT GETDATE()
          )
        `);
        
        await pool.request()
          .input('counterValue', sql.Int, orderNumber)
          .query(`
            INSERT INTO order_counter (counter_name, counter_value, last_updated)
            VALUES ('daily_orders', @counterValue, GETDATE())
          `);
      }
      
      console.log(`📊 Order counter incremented to: ${orderNumber}`);
    } catch (counterErr) {
      console.error('Error managing order counter:', counterErr);
      // Continue without counter if it fails
      orderNumber = Date.now();
    }
    
    // Check if table already has items with a ReceiptNo (existing unpaid order)
    const existingReceiptCheck = suspendOrders.recordset.find(item => item.ReceiptNo != null && item.ReceiptNo !== '');
    
    // Generate receipt number: both unit and counter from sysconfig
    let finalReceiptNo = receiptNo;
    
    // If a receiptNo already exists in the database for this table, use it (don't increment counter)
    if (!finalReceiptNo && existingReceiptCheck && existingReceiptCheck.ReceiptNo) {
      finalReceiptNo = existingReceiptCheck.ReceiptNo;
      console.log(`♻️ Table ${tableNumber} already has ReceiptNo: ${finalReceiptNo}`);
      console.log(`✅ Reusing existing receipt (NOT incrementing sysconfig.ReceiptNo)`);
    }
    // Only generate NEW receipt number if this is truly a new order
    else if (!finalReceiptNo) {
      try {
        // Get both Unit and ReceiptNo from sysconfig (with NOLOCK to read latest value)
        const sysconfigResult = await pool.request().query(`SELECT Unit, ReceiptNo FROM sysconfig WITH (NOLOCK)`);
        if (sysconfigResult.recordset.length > 0) {
          // Get unit from sysconfig and convert to string
          const unitValue = sysconfigResult.recordset[0].Unit;
          const unit = unitValue !== null && unitValue !== undefined ? unitValue.toString() : '1';
          
          // Get counter from sysconfig
          const counter = parseInt(sysconfigResult.recordset[0].ReceiptNo) || 1;
          const receiptCounter = counter.toString().padStart(8, '0');
          
          // Combine: unit + counter (e.g., "1" + "00000001" = "100000001")
          finalReceiptNo = unit + receiptCounter;
          console.log(`📋 NEW ORDER - Generated receipt number: ${finalReceiptNo} (unit: ${unit}, counter: ${receiptCounter})`);
          console.log(`📊 sysconfig.Unit raw value: ${unitValue} (type: ${typeof unitValue})`);
          console.log(`📊 sysconfig.ReceiptNo raw value: ${sysconfigResult.recordset[0].ReceiptNo}`);
          
          // Increment sysconfig counter for next order (ONLY for new orders)
          const nextCounter = counter + 1;
          await pool.request()
            .input('newReceiptNo', sql.Int, nextCounter)
            .query('UPDATE sysconfig SET ReceiptNo = @newReceiptNo');
          
          console.log(`✅ NEW ORDER - Incremented sysconfig ReceiptNo from ${counter} to ${nextCounter}`);
        } else {
          finalReceiptNo = '100000001';
        }
      } catch (err) {
        console.error('Error generating receipt number:', err);
        finalReceiptNo = `RCP${orderNumber}`;
      }
    } else {
      console.log(`✅ Using provided ReceiptNo: ${finalReceiptNo} (NOT incrementing counter)`);
    }
    
    // Update suspend orders with receipt number and mark as confirmed
    // Note: KotPrint is NOT updated here to preserve manual database changes
    await pool.request()
      .input('tableNumber', sql.NVarChar, tableNumber)
      .input('receiptNo', sql.NVarChar, finalReceiptNo)
      .input('salesMan', sql.NVarChar, salesMan)
      .query(`
        UPDATE inv_suspend 
        SET ReceiptNo = @receiptNo, SalesMan = @salesMan
        WHERE [Table] = @tableNumber
      `);
    
    console.log(`✅ Confirmed order for table ${tableNumber} with receipt ${finalReceiptNo}`);
    console.log(`📈 Order number: ${orderNumber}`);
    
    res.json({ 
      success: true, 
      receiptNo: finalReceiptNo,
      orderNumber: orderNumber,
      orderCount: suspendOrders.recordset.length 
    });
  } catch (err) {
    console.error('Error confirming order:', err);
    res.status(500).json({ error: 'Failed to confirm order' });
  }
});

// Get current order counter
app.get('/api/counter/:counterName', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const { counterName } = req.params;
    
    const result = await pool.request()
      .input('counterName', sql.NVarChar, counterName)
      .query(`
        SELECT counter_value, last_updated FROM order_counter 
        WHERE counter_name = @counterName
      `);
    
    if (result.recordset.length > 0) {
      res.json({ 
        success: true, 
        counterName: counterName,
        value: result.recordset[0].counter_value,
        lastUpdated: result.recordset[0].last_updated
      });
    } else {
      res.json({ 
        success: true, 
        counterName: counterName,
        value: 0,
        lastUpdated: null
      });
    }
  } catch (err) {
    console.error('Error getting counter:', err);
    res.status(500).json({ error: 'Failed to get counter' });
  }
});

// Reset order counter
app.post('/api/counter/:counterName/reset', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const { counterName } = req.params;
    const { resetValue = 0 } = req.body;
    
    // Create table if it doesn't exist
    await pool.request().query(`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='order_counter' AND xtype='U')
      CREATE TABLE order_counter (
        counter_name NVARCHAR(50) PRIMARY KEY,
        counter_value INT NOT NULL,
        last_updated DATETIME DEFAULT GETDATE()
      )
    `);
    
    // Update or insert counter
    await pool.request()
      .input('counterName', sql.NVarChar, counterName)
      .input('resetValue', sql.Int, resetValue)
      .query(`
        IF EXISTS (SELECT 1 FROM order_counter WHERE counter_name = @counterName)
          UPDATE order_counter 
          SET counter_value = @resetValue, last_updated = GETDATE()
          WHERE counter_name = @counterName
        ELSE
          INSERT INTO order_counter (counter_name, counter_value, last_updated)
          VALUES (@counterName, @resetValue, GETDATE())
      `);
    
    console.log(`🔄 Counter '${counterName}' reset to: ${resetValue}`);
    res.json({ 
      success: true, 
      counterName: counterName,
      newValue: resetValue
    });
  } catch (err) {
    console.error('Error resetting counter:', err);
    res.status(500).json({ error: 'Failed to reset counter' });
  }
});

// Clear suspend orders for a table (cancel order)
app.delete('/api/suspend-orders/table/:tableNumber', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const { tableNumber } = req.params;
    
    const result = await pool.request()
      .input('tableNumber', sql.NVarChar, tableNumber)
      .query('DELETE FROM inv_suspend WHERE [Table] = @tableNumber');
    
    console.log(`✅ Cleared all suspend orders for table ${tableNumber}`);
    res.json({ success: true, deletedCount: result.rowsAffected[0] });
  } catch (err) {
    console.error('Error clearing suspend orders:', err);
    res.status(500).json({ error: 'Failed to clear suspend orders' });
  }
});

// ==================== SALES ORDER POST PROCESS ====================

// Post sales order using stored procedure
app.post('/api/sales-order/post', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    console.log('📄 Processing sales order post request...');

    const {
      docAction,
      customerCode,
      customerName,
      salesmanCode,
      address,
      iid,
      tempDocNo,
      creditPeriod,
      orgDocNo,
      documentDate,
      expecteDate,
      poDate,
      locaCode,
      manualNo,
      reference,
      remarks,
      grossAmount,
      discPer,
      discAmount,
      taxPer,
      taxAmount,
      netAmount,
      costCenter,
      otherCharge,
      recall,
      quoRecall,
      quotation,
      saveDocNo,
      salesType,
      priceLevel,
      roudAmt,
      sheduled,
      freght,
      orderConfirm,
      userName
    } = req.body;

    const finalIid = 'SON';
    const finalLocaCode = normalizeLocaCode(locaCode);
    const finalCostCenter = normalizeCostCenter(costCenter);

    console.log(`📋 Sales Order Post - DocAction: ${docAction}, Customer: ${customerCode}, Amount: ${netAmount}`);

    const transaction = new sql.Transaction(pool);
    await transaction.begin(sql.ISOLATION_LEVEL.SERIALIZABLE);

    try {
      const docNoResult = await new sql.Request(transaction)
        .input('transactionId', sql.VarChar(5), finalIid)
        .input('locaCode', sql.VarChar(5), finalLocaCode)
        .input('costCenter', sql.VarChar(10), finalCostCenter)
        .query(`
          SELECT TOP 1
            orgdocumentno AS OrgDocumentNo,
            Prifix AS Prefix
          FROM gen_documentno WITH (UPDLOCK, HOLDLOCK)
          WHERE TransactionId = @transactionId
            AND LocaCode = @locaCode
            AND Costcenter = @costCenter
        `);

      if (docNoResult.recordset.length === 0) {
        throw new Error(`Document number setup missing for TransactionId=${finalIid}, LocaCode=${finalLocaCode}, Costcenter=${finalCostCenter}`);
      }

      const docRow = docNoResult.recordset[0];
      const prefix = (docRow.Prefix || 'SO').toString().trim();
      const sequence = (docRow.OrgDocumentNo || 0).toString().trim().padStart(8, '0');
      const generatedOrgDocNo = `${finalLocaCode}${prefix}${sequence}`;

      // Call the stored procedure after temp rows are ready.
      const result = await new sql.Request(transaction)
        .input('p_DocAction', sql.VarChar(2), docAction || 'P')
        .input('p_CustomerCode', sql.VarChar(20), customerCode)
        .input('p_CustomerName', sql.VarChar(50), customerName)
        .input('p_SalesmanCode', sql.VarChar(20), salesmanCode)
        .input('p_Address', sql.VarChar(150), address || '')
        .input('p_Iid', sql.VarChar(5), finalIid)
        .input('p_TempDocNo', sql.VarChar(20), tempDocNo)
        .input('p_CreditPeriod', sql.Int, creditPeriod || 30)
        .input('p_OrgDocNo', sql.VarChar(20), generatedOrgDocNo)
        .input('p_DocumentDate', sql.DateTime, new Date(documentDate))
        .input('p_ExpecteDate', sql.DateTime, expecteDate ? new Date(expecteDate) : new Date())
        .input('p_PoDate', sql.DateTime, poDate ? new Date(poDate) : new Date())
        .input('p_LocaCode', sql.VarChar(5), finalLocaCode)
        .input('p_ManualNo', sql.VarChar(20), manualNo || '')
        .input('p_Reference', sql.VarChar(30), reference || '')
        .input('p_Remarks', sql.VarChar(100), remarks || '')
        .input('p_GrossAmount', sql.Decimal(10, 3), parseFloat(grossAmount) || 0)
        .input('p_DiscPer', sql.Decimal(10, 3), parseFloat(discPer) || 0)
        .input('p_DiscAmount', sql.Decimal(10, 3), parseFloat(discAmount) || 0)
        .input('p_TaxPer', sql.Decimal(10, 3), parseFloat(taxPer) || 0)
        .input('p_TaxAmount', sql.Decimal(10, 3), parseFloat(taxAmount) || 0)
        .input('p_NetAmount', sql.Decimal(10, 3), parseFloat(netAmount) || 0)
        .input('p_CostCenter', sql.VarChar(10), finalCostCenter)
        .input('p_OtherCharge', sql.Decimal(10, 3), parseFloat(otherCharge) || 0)
        .input('p_Recall', sql.Bit, recall || false)
        .input('p_QuoRecall', sql.Bit, quoRecall || false)
        .input('p_Quotation', sql.VarChar(20), quotation || '')
        .input('p_SaveDocNo', sql.VarChar(20), saveDocNo || '')
        .input('p_SalesType', sql.VarChar(20), salesType || 'Retail')
        .input('p_PriceLevel', sql.VarChar(15), priceLevel || 'Standard')
        .input('p_RoudAmt', sql.Decimal(10, 3), parseFloat(roudAmt) || 0)
        .input('p_Sheduled', sql.Bit, sheduled || false)
        .input('p_Freght', sql.Bit, freght || false)
        .input('p_OrderConfirm', sql.Bit, orderConfirm || false)
        .input('p_User_Name', sql.VarChar(50), userName)
        .execute('inv_USp_SalesOrderPostProcess');

      await new sql.Request(transaction)
        .input('transactionId', sql.VarChar(5), finalIid)
        .input('locaCode', sql.VarChar(5), finalLocaCode)
        .input('costCenter', sql.VarChar(10), finalCostCenter)
        .query(`
          UPDATE gen_documentno
          SET tmpdocumentno = tmpdocumentno + 1
          WHERE TransactionId = @transactionId
            AND LocaCode = @locaCode
            AND Costcenter = @costCenter
        `);

      await transaction.commit();

      console.log(`✅ Sales order posted successfully via stored procedure - Document No: ${generatedOrgDocNo}`);

      res.json({
        success: true,
        message: 'Sales order posted successfully',
        documentNo: generatedOrgDocNo,
        data: result
      });
    } catch (postErr) {
      await transaction.rollback().catch(() => {});
      throw postErr;
    }

  } catch (err) {
    console.error('❌ Error posting sales order:', err);
    res.status(500).json({
      error: 'Failed to post sales order',
      details: err.message,
      success: false
    });
  }
});

// ==================== QUOTATION POST PROCESS ====================

app.post('/api/quotation/post', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const {
      docAction = 'P',
      customerCode,
      customerName,
      salesmanCode,
      address = '',
      tempDocNo,
      documentDate,
      locaCode = '01',
      manualNo = '',
      reference = '',
      remarks = '',
      grossAmount = 0,
      discPer = 0,
      discAmount = 0,
      taxPer = 0,
      taxAmount = 0,
      netAmount = 0,
      costCenter = '000001',
      otherCharge = 0,
      recall = false,
      saveDocNo = '',
      salesType = 'Retail',
      priceLevel = 'Standard',
      roudAmt = 0,
      userName = ''
    } = req.body;

    if (!customerCode || !salesmanCode || !tempDocNo) {
      return res.status(400).json({
        success: false,
        error: 'Missing required fields: customerCode, salesmanCode, tempDocNo'
      });
    }

    const finalIid = 'QUO';
    const finalLocaCode = normalizeLocaCode(locaCode);
    const finalCostCenter = normalizeCostCenter(costCenter);

    console.log(`📋 Quotation Post - DocAction: ${docAction}, Customer: ${customerCode}, Amount: ${netAmount}`);

    const transaction = new sql.Transaction(pool);
    await transaction.begin(sql.ISOLATION_LEVEL.SERIALIZABLE);

    try {
      const docNoResult = await new sql.Request(transaction)
        .input('transactionId', sql.VarChar(5), finalIid)
        .input('locaCode', sql.VarChar(5), finalLocaCode)
        .input('costCenter', sql.VarChar(10), finalCostCenter)
        .query(`
          SELECT TOP 1
            orgdocumentno AS OrgDocumentNo,
            Prifix AS Prefix
          FROM gen_documentno WITH (UPDLOCK, HOLDLOCK)
          WHERE TransactionId = @transactionId
            AND LocaCode = @locaCode
            AND Costcenter = @costCenter
        `);

      if (docNoResult.recordset.length === 0) {
        throw new Error(`Document number setup missing for TransactionId=${finalIid}, LocaCode=${finalLocaCode}, Costcenter=${finalCostCenter}`);
      }

      const docRow = docNoResult.recordset[0];
      const prefix = (docRow.Prefix || 'QO').toString().trim();
      const sequence = (docRow.OrgDocumentNo || 0).toString().trim().padStart(8, '0');
      const generatedOrgDocNo = `${finalLocaCode}${prefix}${sequence}`;

      const result = await new sql.Request(transaction)
        .input('p_DocAction', sql.VarChar(2), docAction || 'P')
        .input('p_CustomerCode', sql.VarChar(20), customerCode)
        .input('p_CustomerName', sql.VarChar(50), customerName || customerCode)
        .input('p_SalesmanCode', sql.VarChar(20), salesmanCode)
        .input('p_Address', sql.VarChar(150), address || '')
        .input('p_Iid', sql.VarChar(5), finalIid)
        .input('p_TempDocNo', sql.VarChar(20), tempDocNo)
        .input('p_OrgDocNo', sql.VarChar(20), generatedOrgDocNo)
        .input('p_DocumentDate', sql.DateTime, documentDate ? new Date(documentDate) : new Date())
        .input('p_LocaCode', sql.VarChar(5), finalLocaCode)
        .input('p_ManualNo', sql.VarChar(20), manualNo || '')
        .input('p_Reference', sql.VarChar(30), reference || '')
        .input('p_Remarks', sql.VarChar(100), remarks || '')
        .input('p_GrossAmount', sql.Decimal(10, 3), parseFloat(grossAmount) || 0)
        .input('p_DiscPer', sql.Decimal(10, 3), parseFloat(discPer) || 0)
        .input('p_DiscAmount', sql.Decimal(10, 3), parseFloat(discAmount) || 0)
        .input('p_TaxPer', sql.Decimal(10, 3), parseFloat(taxPer) || 0)
        .input('p_TaxAmount', sql.Decimal(10, 3), parseFloat(taxAmount) || 0)
        .input('p_NetAmount', sql.Decimal(10, 3), parseFloat(netAmount) || 0)
        .input('p_CostCenter', sql.VarChar(10), finalCostCenter)
        .input('p_OtherCharge', sql.Decimal(10, 3), parseFloat(otherCharge) || 0)
        .input('p_Recall', sql.Bit, recall || false)
        .input('p_SaveDocNo', sql.VarChar(20), saveDocNo || '')
        .input('p_SalesType', sql.VarChar(20), salesType || 'Retail')
        .input('p_PriceLevel', sql.VarChar(15), priceLevel || 'Standard')
        .input('p_RoudAmt', sql.Decimal(10, 3), parseFloat(roudAmt) || 0)
        .input('p_User_Name', sql.VarChar(50), userName || salesmanCode)
        .execute('inv_USp_QuotationPostProcess');

      await new sql.Request(transaction)
        .input('transactionId', sql.VarChar(5), finalIid)
        .input('locaCode', sql.VarChar(5), finalLocaCode)
        .input('costCenter', sql.VarChar(10), finalCostCenter)
        .query(`
          UPDATE gen_documentno
          SET tmpdocumentno = tmpdocumentno + 1
          WHERE TransactionId = @transactionId
            AND LocaCode = @locaCode
            AND Costcenter = @costCenter
        `);

      await transaction.commit();

      console.log(`✅ Quotation posted successfully - Document No: ${generatedOrgDocNo}`);

      res.json({
        success: true,
        message: 'Quotation posted successfully',
        documentNo: generatedOrgDocNo,
        data: result
      });
    } catch (postErr) {
      await transaction.rollback().catch(() => {});
      throw postErr;
    }
  } catch (err) {
    console.error('❌ Error posting quotation:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to post quotation',
      details: err.message,
      errorCode: err.code,
      errorNumber: err.number
    });
  }
});

// ==================== QUOTATION RECALL ====================

app.get('/api/quotations/recall', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const customerCode = (req.query.customerCode || '').toString().trim();

    if (!customerCode) {
      return res.status(400).json({ success: false, error: 'customerCode is required' });
    }

    if (isLocalCustomerCode(customerCode)) {
      return res.json([]);
    }

    const result = await bindCustomerCodeInput(pool.request(), 'customerCode', customerCode)
      .query(`
        SELECT TOP 50
          DocumentNo,
          CONVERT(varchar(10), DocumentDate, 120) AS DocumentDate,
          NetAmount,
          BalanceAmount,
          SalesType,
          PriceLevel,
          Remarks,
          LocaCode,
          CostCenter,
          CustomerCode
        FROM inv_invoiceheader
        WHERE Iid = 'QUO'
          AND StatusId = 1
          AND CustomerCode = @customerCode
        ORDER BY DocumentDate DESC, DocumentNo DESC
      `);

    res.json(result.recordset);
  } catch (err) {
    console.error('❌ Error loading quotations for recall:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load quotations for recall',
      details: err.message
    });
  }
});

app.get('/api/quotations/:documentNo/recall', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const documentNo = (req.params.documentNo || '').toString().trim();
    const customerCode = (req.query.customerCode || '').toString().trim();

    if (!documentNo) {
      return res.status(400).json({ success: false, error: 'documentNo is required' });
    }

    const headerResult = await pool.request()
      .input('documentNo', sql.VarChar(20), documentNo)
      .input('customerCode', sql.NVarChar(50), customerCode)
      .query(`
        SELECT TOP 1
          DocumentNo,
          CONVERT(varchar(30), DocumentDate, 126) AS DocumentDate,
          CustomerCode,
          SalesmanCode,
          ManualNo,
          Reference,
          Remarks,
          GrossAmount,
          DiscPer,
          DiscAmount,
          TaxPer,
          TaxAmount,
          NetAmount,
          SalesType,
          PriceLevel,
          LocaCode,
          CostCenter
        FROM inv_invoiceheader
        WHERE Iid = 'QUO'
          AND StatusId = 1
          AND DocumentNo = @documentNo
          AND (@customerCode = '' OR CustomerCode = @customerCode)
      `);

    if (headerResult.recordset.length === 0) {
      return res.status(404).json({ success: false, error: 'Quotation not found' });
    }

    const header = headerResult.recordset[0];
    const locaCode = normalizeLocaCode(header.LocaCode);
    const costCenter = normalizeCostCenter(header.CostCenter);

    const detailResult = await pool.request()
      .input('documentNo', sql.VarChar(20), documentNo)
      .input('locaCode', sql.VarChar(5), locaCode)
      .input('costCenter', sql.VarChar(10), costCenter)
      .query(`
        SELECT
          ProductCode,
          ProductDescription,
          LongDescription,
          Margin,
          Unit,
          PackSize,
          Qty,
          BQTY,
          FreeQty,
          CostPrice,
          UnitPrice,
          WholeSalePrice,
          BatchNo,
          CONVERT(varchar(30), ExpiryDate, 126) AS ExpiryDate,
          DiscPer,
          DiscAmount,
          Amount,
          StockLoca,
          Tax
        FROM inv_invoicedetails
        WHERE Iid = 'QUO'
          AND StatusId = 1
          AND DocumentNo = @documentNo
          AND LocaCode = @locaCode
          AND CostCenter = @costCenter
        ORDER BY ProductCode
      `);

    res.json({
      header,
      details: detailResult.recordset
    });
  } catch (err) {
    console.error('❌ Error loading quotation recall details:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load quotation details',
      details: err.message
    });
  }
});

// ==================== SALES ORDER RECALL ====================

app.get('/api/sales-orders/recall', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const customerCode = (req.query.customerCode || '').toString().trim();

    if (!customerCode) {
      return res.status(400).json({ success: false, error: 'customerCode is required' });
    }

    if (isLocalCustomerCode(customerCode)) {
      return res.json([]);
    }

    const result = await bindCustomerCodeInput(pool.request(), 'customerCode', customerCode)
      .query(`
        SELECT TOP 50
          DocumentNo,
          CONVERT(varchar(10), DocumentDate, 120) AS DocumentDate,
          NetAmount,
          BalanceAmount,
          SalesType,
          PriceLevel,
          Remarks,
          LocaCode,
          CostCenter,
          CustomerCode
        FROM inv_invoiceheader
        WHERE Iid = 'SON'
          AND StatusId = 1
          AND CustomerCode = @customerCode
        ORDER BY DocumentDate DESC, DocumentNo DESC
      `);

    res.json(result.recordset);
  } catch (err) {
    console.error('❌ Error loading sales orders for recall:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load sales orders for recall',
      details: err.message
    });
  }
});

app.get('/api/sales-orders/:documentNo/recall', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const documentNo = (req.params.documentNo || '').toString().trim();
    const customerCode = (req.query.customerCode || '').toString().trim();

    if (!documentNo) {
      return res.status(400).json({ success: false, error: 'documentNo is required' });
    }

    const headerResult = await pool.request()
      .input('documentNo', sql.VarChar(20), documentNo)
      .input('customerCode', sql.NVarChar(50), customerCode)
      .query(`
        SELECT TOP 1
          DocumentNo,
          CONVERT(varchar(30), DocumentDate, 126) AS DocumentDate,
          CustomerCode,
          SalesmanCode,
          ManualNo,
          Reference,
          Remarks,
          GrossAmount,
          DiscPer,
          DiscAmount,
          TaxPer,
          TaxAmount,
          NetAmount,
          SalesType,
          PriceLevel,
          LocaCode,
          CostCenter
        FROM inv_invoiceheader
        WHERE Iid = 'SON'
          AND StatusId = 1
          AND DocumentNo = @documentNo
          AND (@customerCode = '' OR CustomerCode = @customerCode)
      `);

    if (headerResult.recordset.length === 0) {
      return res.status(404).json({ success: false, error: 'Sales order not found' });
    }

    const header = headerResult.recordset[0];
    const locaCode = normalizeLocaCode(header.LocaCode);
    const costCenter = normalizeCostCenter(header.CostCenter);

    const detailResult = await pool.request()
      .input('documentNo', sql.VarChar(20), documentNo)
      .input('locaCode', sql.VarChar(5), locaCode)
      .input('costCenter', sql.VarChar(10), costCenter)
      .query(`
        SELECT
          ProductCode,
          ProductDescription,
          LongDescription,
          Margin,
          Unit,
          PackSize,
          Qty,
          BQTY,
          FreeQty,
          CostPrice,
          UnitPrice,
          WholeSalePrice,
          BatchNo,
          CONVERT(varchar(30), ExpiryDate, 126) AS ExpiryDate,
          DiscPer,
          DiscAmount,
          Amount,
          StockLoca,
          Tax
        FROM inv_invoicedetails
        WHERE Iid = 'SON'
          AND StatusId = 1
          AND DocumentNo = @documentNo
          AND LocaCode = @locaCode
          AND CostCenter = @costCenter
        ORDER BY ProductCode
      `);

    res.json({
      header,
      details: detailResult.recordset
    });
  } catch (err) {
    console.error('❌ Error loading sales order recall details:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load sales order details',
      details: err.message
    });
  }
});

// ==================== CRN / CUSTOMER RETURN ====================

app.get('/api/invoices/recall', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const customerCode = (req.query.customerCode || '').toString().trim();

    if (!customerCode) {
      return res.status(400).json({ success: false, error: 'customerCode is required' });
    }

    if (isLocalCustomerCode(customerCode)) {
      return res.json([]);
    }

    const result = await bindCustomerCodeInput(pool.request(), 'customerCode', customerCode)
      .query(`
        SELECT TOP 50
          DocumentNo,
          CONVERT(varchar(10), DocumentDate, 120) AS DocumentDate,
          NetAmount,
          BalanceAmount,
          SalesType,
          PriceLevel,
          Remarks,
          LocaCode,
          CostCenter,
          CustomerCode
        FROM inv_invoiceheader
        WHERE Iid = 'INV'
          AND StatusId = 1
          AND CustomerCode = @customerCode
        ORDER BY DocumentDate DESC, DocumentNo DESC
      `);

    res.json(result.recordset);
  } catch (err) {
    console.error('❌ Error loading invoices for recall:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load invoices for recall',
      details: err.message
    });
  }
});

app.get('/api/invoices/:documentNo/recall', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const documentNo = (req.params.documentNo || '').toString().trim();
    const customerCode = (req.query.customerCode || '').toString().trim();

    if (!documentNo) {
      return res.status(400).json({ success: false, error: 'documentNo is required' });
    }

    const headerResult = await pool.request()
      .input('documentNo', sql.VarChar(20), documentNo)
      .input('customerCode', sql.NVarChar(50), customerCode)
      .query(`
        SELECT TOP 1
          DocumentNo,
          CONVERT(varchar(30), DocumentDate, 126) AS DocumentDate,
          CustomerCode,
          SalesmanCode,
          ManualNo,
          Reference,
          Remarks,
          CreditPeriod,
          GrossAmount,
          DiscPer,
          DiscAmount,
          TaxPer,
          TaxAmount,
          NetAmount,
          BalanceAmount,
          SalesType,
          PriceLevel,
          LocaCode,
          CostCenter
        FROM inv_invoiceheader
        WHERE Iid = 'INV'
          AND StatusId = 1
          AND DocumentNo = @documentNo
          AND (@customerCode = '' OR CustomerCode = @customerCode)
      `);

    if (headerResult.recordset.length === 0) {
      return res.status(404).json({ success: false, error: 'Invoice not found' });
    }

    const header = headerResult.recordset[0];
    const locaCode = normalizeLocaCode(header.LocaCode);
    const costCenter = normalizeCostCenter(header.CostCenter);

    const detailResult = await pool.request()
      .input('documentNo', sql.VarChar(20), documentNo)
      .input('locaCode', sql.VarChar(5), locaCode)
      .input('costCenter', sql.VarChar(10), costCenter)
      .query(`
        SELECT
          ProductCode,
          ProductDescription,
          LongDescription,
          Margin,
          Unit,
          PackSize,
          Qty,
          BQTY,
          FreeQty,
          CostPrice,
          UnitPrice,
          WholeSalePrice,
          BatchNo,
          CONVERT(varchar(30), ExpiryDate, 126) AS ExpiryDate,
          DiscPer,
          DiscAmount,
          Amount,
          StockLoca,
          Tax
        FROM inv_invoicedetails
        WHERE Iid = 'INV'
          AND StatusId = 1
          AND DocumentNo = @documentNo
          AND LocaCode = @locaCode
          AND CostCenter = @costCenter
        ORDER BY ProductCode
      `);

    res.json({
      header,
      details: detailResult.recordset
    });
  } catch (err) {
    console.error('❌ Error loading invoice recall details:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load invoice details',
      details: err.message
    });
  }
});

app.get('/api/crn/recall', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const customerCode = (req.query.customerCode || '').toString().trim();

    if (!customerCode) {
      return res.status(400).json({ success: false, error: 'customerCode is required' });
    }

    if (isLocalCustomerCode(customerCode)) {
      return res.json([]);
    }

    const result = await bindCustomerCodeInput(pool.request(), 'customerCode', customerCode)
      .query(`
        SELECT TOP 50
          DocumentNo,
          CONVERT(varchar(10), DocumentDate, 120) AS DocumentDate,
          NetAmount,
          BalanceAmount,
          SalesType,
          PriceLevel,
          Remarks,
          LocaCode,
          CostCenter,
          CustomerCode
        FROM inv_invoiceheader
        WHERE Iid = 'CRN'
          AND StatusId = 1
          AND CustomerCode = @customerCode
        ORDER BY DocumentDate DESC, DocumentNo DESC
      `);

    res.json(result.recordset);
  } catch (err) {
    console.error('❌ Error loading CRNs for recall:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load CRNs for recall',
      details: err.message,
    });
  }
});

app.get('/api/crn/:documentNo/recall', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const documentNo = (req.params.documentNo || '').toString().trim();
    const customerCode = (req.query.customerCode || '').toString().trim();

    if (!documentNo) {
      return res.status(400).json({ success: false, error: 'documentNo is required' });
    }

    const headerResult = await pool.request()
      .input('documentNo', sql.VarChar(20), documentNo)
      .input('customerCode', sql.NVarChar(50), customerCode)
      .query(`
        SELECT TOP 1
          h.DocumentNo,
          CONVERT(varchar(30), h.DocumentDate, 126) AS DocumentDate,
          h.CustomerCode,
          ISNULL(c.CustomerName, h.CustomerCode) AS CustomerName,
          ISNULL(c.Address1, '') AS CustomerAddress,
          h.SalesmanCode,
          h.ManualNo,
          h.Reference,
          h.Remarks,
          h.GrossAmount,
          h.DiscPer,
          h.DiscAmount,
          h.TaxPer,
          h.TaxAmount,
          h.NetAmount,
          h.BalanceAmount,
          h.SalesType,
          h.PriceLevel,
          h.LocaCode,
          h.CostCenter
        FROM inv_invoiceheader h
        LEFT JOIN gen_customer c ON c.CustomerCode = h.CustomerCode
        WHERE h.Iid = 'CRN'
          AND h.StatusId = 1
          AND h.DocumentNo = @documentNo
          AND (@customerCode = '' OR h.CustomerCode = @customerCode)
      `);

    if (headerResult.recordset.length === 0) {
      return res.status(404).json({ success: false, error: 'CRN not found' });
    }

    const header = headerResult.recordset[0];
    const locaCode = normalizeLocaCode(header.LocaCode);
    const costCenter = normalizeCostCenter(header.CostCenter);

    const detailResult = await pool.request()
      .input('documentNo', sql.VarChar(20), documentNo)
      .input('locaCode', sql.VarChar(5), locaCode)
      .input('costCenter', sql.VarChar(10), costCenter)
      .query(`
        SELECT
          ProductCode,
          ProductDescription,
          LongDescription,
          Margin,
          Unit,
          PackSize,
          Qty,
          BQTY,
          FreeQty,
          CostPrice,
          UnitPrice,
          WholeSalePrice,
          BatchNo,
          CONVERT(varchar(30), ExpiryDate, 126) AS ExpiryDate,
          DiscPer,
          DiscAmount,
          Amount,
          StockLoca,
          Tax
        FROM inv_invoicedetails
        WHERE Iid = 'CRN'
          AND StatusId = 1
          AND DocumentNo = @documentNo
          AND LocaCode = @locaCode
          AND CostCenter = @costCenter
        ORDER BY ProductCode
      `);

    res.json({
      header,
      details: detailResult.recordset,
    });
  } catch (err) {
    console.error('❌ Error loading CRN recall details:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load CRN details',
      details: err.message,
    });
  }
});

app.post('/api/crn/post', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const {
      docAction = 'P',
      customerCode,
      customerName,
      salesmanCode,
      address = '',
      tempDocNo,
      tourCode = '',
      documentDate,
      locaCode = '01',
      manualNo = '',
      reference = '',
      remarks = '',
      creditPeriod = 0,
      grossAmount = 0,
      discPer = 0,
      discAmount = 0,
      taxPer = 0,
      taxAmount = 0,
      netAmount = 0,
      ledgerCode1 = '',
      doubleEntery1 = '',
      ledgerCode2 = '',
      ledgerCode3 = '',
      doubleEntery2 = '',
      doubleEntery3 = '',
      costCenter = '000001',
      jobNumber = '',
      otherCharge = 0,
      recall = false,
      invRecall = false,
      toDispach = false,
      saveDocNo = '',
      salesType = 'Retail',
      priceLevel = 'Standard',
      invoice = '',
      returnType = 'Customer Return',
      dispatch = '',
      tempCreditAmt = 0,
      roudAmt = 0,
      invAmount = 0,
      user_Name,
      userName
    } = req.body;

    if (!customerCode || !salesmanCode || !tempDocNo) {
      return res.status(400).json({
        success: false,
        error: 'Missing required fields: customerCode, salesmanCode, tempDocNo'
      });
    }

    const finalIid = 'CRN';
    const finalLocaCode = normalizeLocaCode(locaCode);
    const finalCostCenter = normalizeCostCenter(costCenter);
    const finalUserName = user_Name || userName || salesmanCode;

    const transaction = new sql.Transaction(pool);
    await transaction.begin(sql.ISOLATION_LEVEL.SERIALIZABLE);

    try {
      const docNoResult = await new sql.Request(transaction)
        .input('transactionId', sql.VarChar(5), finalIid)
        .input('locaCode', sql.VarChar(5), finalLocaCode)
        .input('costCenter', sql.VarChar(10), finalCostCenter)
        .query(`
          SELECT TOP 1
            orgdocumentno AS OrgDocumentNo,
            Prifix AS Prefix
          FROM gen_documentno WITH (UPDLOCK, HOLDLOCK)
          WHERE TransactionId = @transactionId
            AND LocaCode = @locaCode
            AND Costcenter = @costCenter
        `);

      if (docNoResult.recordset.length === 0) {
        throw new Error(`Document number setup missing for TransactionId=${finalIid}, LocaCode=${finalLocaCode}, Costcenter=${finalCostCenter}`);
      }

      const docRow = docNoResult.recordset[0];
      const prefix = (docRow.Prefix || 'CRN').toString().trim();
      const sequence = (docRow.OrgDocumentNo || 0).toString().trim().padStart(8, '0');
      const generatedOrgDocNo = `${finalLocaCode}${prefix}${sequence}`;

      const result = await new sql.Request(transaction)
        .input('p_DocAction', sql.VarChar(2), docAction || 'P')
        .input('p_CustomerCode', sql.VarChar(20), customerCode)
        .input('p_CustomerName', sql.VarChar(50), customerName || customerCode)
        .input('p_SalesmanCode', sql.VarChar(20), salesmanCode)
        .input('p_Address', sql.VarChar(150), address || '')
        .input('p_Iid', sql.VarChar(5), finalIid)
        .input('p_TempDocNo', sql.VarChar(20), tempDocNo)
        .input('p_TourCode', sql.VarChar(20), tourCode || '')
        .input('p_OrgDocNo', sql.VarChar(20), generatedOrgDocNo)
        .input('p_DocumentDate', sql.DateTime, documentDate ? new Date(documentDate) : new Date())
        .input('p_LocaCode', sql.VarChar(5), finalLocaCode)
        .input('p_ManualNo', sql.VarChar(20), manualNo || '')
        .input('p_Reference', sql.VarChar(30), reference || '')
        .input('p_Remarks', sql.VarChar(100), remarks || '')
        .input('p_CreditPeriod', sql.Int, parseInt(creditPeriod) || 0)
        .input('p_GrossAmount', sql.Decimal(10, 3), parseFloat(grossAmount) || 0)
        .input('p_DiscPer', sql.Decimal(10, 3), parseFloat(discPer) || 0)
        .input('p_DiscAmount', sql.Decimal(10, 3), parseFloat(discAmount) || 0)
        .input('p_TaxPer', sql.Decimal(10, 3), parseFloat(taxPer) || 0)
        .input('p_TaxAmount', sql.Decimal(10, 3), parseFloat(taxAmount) || 0)
        .input('p_NetAmount', sql.Decimal(10, 3), parseFloat(netAmount) || 0)
        .input('p_LedgerCode1', sql.VarChar(15), ledgerCode1 || '')
        .input('p_DoubleEntery1', sql.VarChar(5), doubleEntery1 || '')
        .input('p_LedgerCode2', sql.VarChar(15), ledgerCode2 || '')
        .input('p_LedgerCode3', sql.VarChar(15), ledgerCode3 || '')
        .input('p_DoubleEntery2', sql.VarChar(5), doubleEntery2 || '')
        .input('p_DoubleEntery3', sql.VarChar(5), doubleEntery3 || '')
        .input('p_CostCenter', sql.VarChar(10), finalCostCenter)
        .input('p_JobNumber', sql.VarChar(10), jobNumber || '')
        .input('p_OtherCharge', sql.Decimal(10, 3), parseFloat(otherCharge) || 0)
        .input('p_Recall', sql.Bit, recall || false)
        .input('p_InvRecall', sql.Bit, invRecall || false)
        .input('p_ToDispach', sql.Bit, toDispach || false)
        .input('p_SaveDocNo', sql.VarChar(20), saveDocNo || '')
        .input('p_SalesType', sql.VarChar(20), salesType || 'Retail')
        .input('p_PriceLevel', sql.VarChar(15), priceLevel || 'Standard')
        .input('p_Invoice', sql.VarChar(20), invoice || '')
        .input('p_Returntype', sql.VarChar(20), returnType || 'Customer Return')
        .input('p_Dispatch', sql.VarChar(20), dispatch || '')
        .input('p_TempCreditAmt', sql.Decimal(10, 3), parseFloat(tempCreditAmt) || 0)
        .input('p_RoudAmt', sql.Decimal(10, 3), parseFloat(roudAmt) || 0)
        .input('p_InvAmount', sql.Decimal(10, 3), parseFloat(invAmount) || 0)
        .input('p_User_Name', sql.VarChar(50), finalUserName)
        .execute('inv_USp_CustomerReturnPostProcess');

      await new sql.Request(transaction)
        .input('transactionId', sql.VarChar(5), finalIid)
        .input('locaCode', sql.VarChar(5), finalLocaCode)
        .input('costCenter', sql.VarChar(10), finalCostCenter)
        .query(`
          UPDATE gen_documentno
          SET tmpdocumentno = tmpdocumentno + 1
          WHERE TransactionId = @transactionId
            AND LocaCode = @locaCode
            AND Costcenter = @costCenter
        `);

      await transaction.commit();

      res.json({
        success: true,
        message: 'CRN posted successfully',
        documentNo: generatedOrgDocNo,
        data: result
      });
    } catch (postErr) {
      await transaction.rollback().catch(() => {});
      throw postErr;
    }
  } catch (err) {
    console.error('❌ Error posting CRN:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to post CRN',
      details: err.message,
      errorCode: err.code,
      errorNumber: err.number
    });
  }
});

// Create HTTP server
const server = http.createServer(app);

// Initialize WebSocket server
initializeWebSocket(server);

const initializeDatabase = require('./initDatabase');

// Start server
initializeDatabase().then(() => {
  server.listen(PORT, '0.0.0.0', () => {
    const os = require('os');
    const nets = os.networkInterfaces();
    let serverIP = 'localhost';
    
    // Find the first non-internal IPv4 address
    Object.keys(nets).forEach(name => {
      nets[name].forEach(net => {
        if (net.family === 'IPv4' && !net.internal) {
          serverIP = net.address;
        }
      });
    });
    
    console.log(`🚀 Server running on http://0.0.0.0:${PORT}`);
    console.log(`📊 API endpoints available at http://localhost:${PORT}/api/`);
    console.log(`📊 Network access available at http://${serverIP}:${PORT}/api/`);
    console.log(`🔌 WebSocket server available at ws://${serverIP}:${PORT}/ws`);
  });
});

// ==================== INVOICE POSTING ====================

// Insert transaction items into inv_temptransaction (required before calling stored procedure)
app.post('/api/invoice/temp-transactions', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const { tempDocNo, locaCode, costCenter, iid, transactions } = req.body;

    if (!tempDocNo || !locaCode || !costCenter || !iid || !Array.isArray(transactions)) {
      return res.status(400).json({
        success: false,
        error: 'Missing required fields: tempDocNo, locaCode, costCenter, iid, transactions array'
      });
    }

    const finalLocaCode = normalizeLocaCode(locaCode);
    const finalCostCenter = normalizeCostCenter(costCenter);

    console.log(`📋 Inserting ${transactions.length} transactions for TempDocNo: ${tempDocNo}`);

    // Delete existing transactions for this temp document
    await pool.request()
      .input('tempDocNo', sql.VarChar(20), tempDocNo)
      .input('locaCode', sql.VarChar(5), finalLocaCode)
      .input('costCenter', sql.VarChar(10), finalCostCenter)
      .input('iid', sql.VarChar(5), iid)
      .query('DELETE FROM inv_temptransaction WHERE TempDocNo = @tempDocNo AND LocaCode = @locaCode AND CostCenter = @costCenter AND Iid = @iid');

    // Insert transactions
    for (const txn of transactions) {
      await pool.request()
        .input('tempDocNo', sql.VarChar(20), tempDocNo)
        .input('locaCode', sql.VarChar(5), finalLocaCode)
        .input('costCenter', sql.VarChar(10), finalCostCenter)
        .input('iid', sql.VarChar(5), iid)
        .input('productCode', sql.VarChar(50), (txn.productCode || '').toString().substring(0, 20))
        .input('productDescription', sql.VarChar(200), (txn.productDescription || '').toString().substring(0, 60))
        .input('longDescription', sql.VarChar(500), (txn.longDescription || '').toString().substring(0, 80))
        .input('margin', sql.Decimal(10, 3), txn.margin || 0)
        .input('unit', sql.VarChar(20), (txn.unit || '').toString().substring(0, 10))
        .input('packSize', sql.Decimal(10, 3), txn.packSize || 1)
        .input('reOrderQty', sql.Decimal(10, 3), txn.reOrderQty || 0)
        .input('qty', sql.Decimal(10, 3), txn.qty || 0)
        .input('pQty', sql.Decimal(10, 3), txn.pQty || 0)
        .input('sQty', sql.Decimal(10, 3), txn.sQty || 0)
        .input('bQty', sql.Decimal(10, 3), txn.bQty || 0)
        .input('freeQty', sql.Decimal(10, 3), txn.freeQty || 0)
        .input('costPrice', sql.Decimal(10, 3), txn.costPrice || 0)
        .input('unitPrice', sql.Decimal(10, 3), txn.unitPrice || 0)
        .input('wholeSalePrice', sql.Decimal(10, 3), txn.wholeSalePrice || 0)
        .input('batchNo', sql.VarChar(50), txn.batchNo || '')
        .input('expiryDate', sql.DateTime, txn.expiryDate || null)
        .input('discPer', sql.Decimal(10, 3), txn.discPer || 0)
        .input('discAmount', sql.Decimal(10, 3), txn.discAmount || 0)
        .input('amount', sql.Decimal(10, 3), txn.amount || 0)
        .input('stockLoca', sql.VarChar(5), normalizeLocaCode(txn.stockLoca || finalLocaCode))
        .input('tax', sql.Decimal(10, 3), txn.tax || 0)
        .input('serialNo', sql.VarChar(50), txn.serialNo || '')
        .input('warrantyPeriod', sql.Int, txn.warrantyPeriod || 0)
        .input('phase', sql.VarChar(20), txn.phase || '')
        .input('periodDays', sql.Int, txn.periodDays || 0)
        .input('isBatch', sql.VarChar(5), txn.isBatch || '0')
        .input('isExpiry', sql.VarChar(5), txn.isExpiry || '0')
        .input('isSemi', sql.VarChar(5), txn.isSemi || '0')
        .input('isAuthority', sql.VarChar(5), txn.isAuthority || '0')
        .input('adjustment', sql.Decimal(10, 3), txn.adjustment || 0)
        .input('avgCostPrice', sql.Decimal(10, 3), txn.avgCostPrice || 0)
        .input('avgDiscount', sql.Decimal(10, 3), txn.avgDiscount || 0)
        .input('avgOther', sql.Decimal(10, 3), txn.avgOther || 0)
        .input('avgVat', sql.Decimal(10, 3), txn.avgVat || 0)
        .input('avgMasterCostPrice', sql.Decimal(10, 3), txn.avgMasterCostPrice || 0)
        .input('refCode', sql.VarChar(50), txn.refCode || null)
        .input('documentDate', sql.DateTime, txn.documentDate ? new Date(txn.documentDate) : null)
        .input('createdDate', sql.DateTime, new Date())
        .input('createdUser', sql.VarChar(50), (txn.createdUser || '').toString().substring(0, 50))
        .query(`
          INSERT INTO inv_temptransaction (
            TempDocNo, LocaCode, CostCenter, Iid, ProductCode, ProductDescription, LongDescription,
            Margin, Unit, PackSize, ReOrderQty, Qty, PQty, SQty, BQty, FreeQty,
            CostPrice, UnitPrice, WholeSalePrice, BatchNo, ExpiryDate, DiscPer,
            DiscAmount, Amount, StockLoca, Tax, SerialNo, WarrantyPeriod,
            Phase, PeriodDays, IsBatch, IsExpiry, IsSemi, IsAuthority, Adjustment,
            AvgCostPrice, AvgDiscount, AvgOther, AvgVat, AvgMasterCostPrice,
            RefCode, DocumentDate, Created_Date, Created_User
          ) VALUES (
            @tempDocNo, @locaCode, @costCenter, @iid, @productCode, @productDescription, @longDescription,
            @margin, @unit, @packSize, @reOrderQty, @qty, @pQty, @sQty, @bQty, @freeQty,
            @costPrice, @unitPrice, @wholeSalePrice, @batchNo, @expiryDate, @discPer,
            @discAmount, @amount, @stockLoca, @tax, @serialNo, @warrantyPeriod,
            @phase, @periodDays, @isBatch, @isExpiry, @isSemi, @isAuthority, @adjustment,
            @avgCostPrice, @avgDiscount, @avgOther, @avgVat, @avgMasterCostPrice,
            @refCode, @documentDate, @createdDate, @createdUser
          )
        `);
    }

    console.log(`✅ Inserted ${transactions.length} transactions successfully`);

    res.json({
      success: true,
      message: `Inserted ${transactions.length} transactions`,
      count: transactions.length
    });

  } catch (err) {
    console.error('❌ Error inserting temp transactions:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to insert transactions',
      details: err.message
    });
  }
});

// Get payment modes from gen_paymentmode table
app.get('/api/payment-modes', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }
    const result = await pool.request().query('SELECT PaymentCode, PaymentMode FROM gen_paymentmode ORDER BY PaymentCode');
    if (result.recordset && result.recordset.length > 0) {
      return res.json(result.recordset);
    }
    // Fallback standard payment modes if table is empty
    return res.json([
      { PaymentCode: '001', PaymentMode: 'Cash' },
      { PaymentCode: '002', PaymentMode: 'Master Card' },
      { PaymentCode: '003', PaymentMode: 'Visa Card' },
      { PaymentCode: '004', PaymentMode: 'Amex Card' },
      { PaymentCode: '006', PaymentMode: 'Credit' },
      { PaymentCode: '007', PaymentMode: 'Cheque' },
      { PaymentCode: '008', PaymentMode: 'Direct Deposit' },
      { PaymentCode: '009', PaymentMode: 'Online' },
    ]);
  } catch (err) {
    console.error('❌ Error fetching gen_paymentmode:', err);
    return res.json([
      { PaymentCode: '001', PaymentMode: 'Cash' },
      { PaymentCode: '002', PaymentMode: 'Master Card' },
      { PaymentCode: '003', PaymentMode: 'Visa Card' },
      { PaymentCode: '004', PaymentMode: 'Amex Card' },
      { PaymentCode: '006', PaymentMode: 'Credit' },
      { PaymentCode: '007', PaymentMode: 'Cheque' },
      { PaymentCode: '008', PaymentMode: 'Direct Deposit' },
      { PaymentCode: '009', PaymentMode: 'Online' },
    ]);
  }
});

// Insert payment items into inv_temppayment (required before calling stored procedure)
app.post('/api/invoice/temp-payments', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const { tempDocNo, locaCode, payments } = req.body;

    if (!tempDocNo || !locaCode || !Array.isArray(payments)) {
      return res.status(400).json({
        success: false,
        error: 'Missing required fields: tempDocNo, locaCode, payments array'
      });
    }

    const finalLocaCode = normalizeLocaCode(locaCode);

    console.log(`💰 Inserting ${payments.length} payments for TempDocNo: ${tempDocNo}`);

    // Delete existing payments for this temp document
    await pool.request()
      .input('tempDocNo', sql.VarChar(20), tempDocNo)
      .input('locaCode', sql.VarChar(5), finalLocaCode)
      .query('DELETE FROM inv_temppayment WHERE TempDocNo = @tempDocNo AND LocaCode = @locaCode');

    // Insert payments
    for (const payment of payments) {
      await pool.request()
        .input('tempDocNo', sql.VarChar(20), tempDocNo)
        .input('locaCode', sql.VarChar(5), finalLocaCode)
        .input('iid', sql.VarChar(5), payment.iid || 'IRE')
        .input('paymentCode', sql.VarChar(20), payment.paymentCode || '001')
        .input('amount', sql.Decimal(10, 3), payment.amount || 0)
        .input('cardChequeNo', sql.VarChar(50), (payment.cardChequeNo || '').toString().substring(0, 20))
        .input('currencyCode', sql.VarChar(10), payment.currencyCode || 'LKR')
        .input('creditPeriod', sql.Int, payment.creditPeriod || 0)
        .input('bankCode', sql.VarChar(20), (payment.bankCode || '').toString().substring(0, 10))
        .input('branchCode', sql.VarChar(20), (payment.branchCode || '').toString().substring(0, 10))
        .input('bankName', sql.VarChar(100), (payment.bankName || '').toString().substring(0, 30))
        .input('branchName', sql.VarChar(100), (payment.branchName || '').toString().substring(0, 30))
        .input(
          'chequeDate',
          sql.DateTime,
          payment.chequeDate ? new Date(payment.chequeDate) : null
        )
        .input('terminalId', sql.VarChar(15), payment.terminalId || '')
        .input('ledgerCode1', sql.VarChar(15), payment.ledgerCode1 || '')
        .input('doubleEntery1', sql.VarChar(5), payment.doubleEntery1 || '')
        .input('ledgerCode2', sql.VarChar(15), payment.ledgerCode2 || '')
        .input('doubleEntery2', sql.VarChar(5), payment.doubleEntery2 || '')
        .query(`
          INSERT INTO inv_temppayment (
            TempDocNo, LocaCode, Iid, PaymentCode, Amount, CardChequeNo, CurrencyCode,
            CreditPeriod, BankCode, BranchCode, BankName, BranchName, ChequeDate,
            TerminalId, LedgerCode1, DoubleEntery1, LedgerCode2, DoubleEntery2
          ) VALUES (
            @tempDocNo, @locaCode, @iid, @paymentCode, @amount, @cardChequeNo, @currencyCode,
            @creditPeriod, @bankCode, @branchCode, @bankName, @branchName, @chequeDate,
            @terminalId, @ledgerCode1, @doubleEntery1, @ledgerCode2, @doubleEntery2
          )
        `);
    }

    console.log(`✅ Inserted ${payments.length} payments successfully`);

    res.json({
      success: true,
      message: `Inserted ${payments.length} payments`,
      count: payments.length
    });

  } catch (err) {
    console.error('❌ Error inserting temp payments:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to insert payments',
      details: err.message
    });
  }
});

// Post invoice using stored procedure inv_USp_InvoicePostProcess
app.post('/api/invoice/post', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const {
      docAction = 'P', // 'P' for Post, 'S' for Save
      customerCode,
      customerName,
      salesmanCode,
      address,
      iid = 'INV',
      tempDocNo,
      orgDocNo,
      tourCode = '',
      documentDate,
      locaCode,
      manualNo = '',
      reference = '',
      deliveryTerms = '',
      paymentTerms = '',
      remarks = '',
      creditPeriod = 0,
      grossAmount,
      discPer = 0,
      discAmount = 0,
      taxPer = 0,
      taxAmount = 0,
      netAmount,
      ledgerCode1 = '',
      doubleEntery1 = '',
      ledgerCode2 = '',
      ledgerCode3 = '',
      doubleEntery2 = '',
      doubleEntery3 = '',
      costCenter,
      jobNumber = '',
      otherCharge = 0,
      recall = false,
      quoRecall = false,
      sonRecall = false,
      disRecall = false,
      toDispach = false,
      saveDocNo = '',
      salesType = '',
      priceLevel = '',
      quotation = '',
      performer = '',
      dispatch = '',
      tempCreditAmt = 0,
      roudAmt = 0,
      poDate = null,
      currancy = 'LKR',
      user_Name,
      // Transaction items will be inserted into inv_temptransaction first
      // Payment items will be inserted into inv_temppayment first
    } = req.body;

    // Validate required fields
    if (!customerCode || !salesmanCode || !tempDocNo || !locaCode || !costCenter || !user_Name) {
      return res.status(400).json({
        success: false,
        error: 'Missing required fields: customerCode, salesmanCode, tempDocNo, locaCode, costCenter, user_Name are required'
      });
    }

    const finalIid = 'INV';
    const finalLocaCode = normalizeLocaCode(locaCode);
    const finalCostCenter = normalizeCostCenter(costCenter);

    console.log(`📋 Posting invoice: TempDocNo=${tempDocNo}, Customer=${customerCode}, Action=${docAction}`);

    const transaction = new sql.Transaction(pool);
    await transaction.begin(sql.ISOLATION_LEVEL.SERIALIZABLE);

    try {
      const docNoResult = await new sql.Request(transaction)
        .input('transactionId', sql.VarChar(5), finalIid)
        .input('locaCode', sql.VarChar(5), finalLocaCode)
        .input('costCenter', sql.VarChar(10), finalCostCenter)
        .query(`
          SELECT TOP 1
            orgdocumentno AS OrgDocumentNo,
            Prifix AS Prefix
          FROM gen_documentno WITH (UPDLOCK, HOLDLOCK)
          WHERE TransactionId = @transactionId
            AND LocaCode = @locaCode
            AND Costcenter = @costCenter
        `);

      if (docNoResult.recordset.length === 0) {
        throw new Error(`Document number setup missing for TransactionId=${finalIid}, LocaCode=${finalLocaCode}, Costcenter=${finalCostCenter}`);
      }

      const docRow = docNoResult.recordset[0];
      const prefix = (docRow.Prefix || 'IN').toString().trim();
      const sequence = (docRow.OrgDocumentNo || 0).toString().trim().padStart(8, '0');
      const generatedOrgDocNo = `${finalLocaCode}${prefix}${sequence}`;

      // Create request for stored procedure
      const request = new sql.Request(transaction);
    
    // Set all parameters (ensure no null values for required fields)
    request.input('p_DocAction', sql.VarChar(2), docAction || 'P');
    request.input('p_CustomerCode', sql.VarChar(20), customerCode);
    request.input('p_CustomerName', sql.VarChar(50), (customerName || customerCode || '').substring(0, 35));
    request.input('p_SalesmanCode', sql.VarChar(20), salesmanCode);
    request.input('p_Address', sql.VarChar(150), (address || '').substring(0, 60));
    request.input('p_Iid', sql.VarChar(5), finalIid);
    request.input('p_TempDocNo', sql.VarChar(20), tempDocNo);
    request.input('p_OrgDocNo', sql.VarChar(20), generatedOrgDocNo.substring(0, 12));
    request.input('p_TourCode', sql.VarChar(20), (tourCode || '').substring(0, 20));
    request.input('p_DocumentDate', sql.DateTime, documentDate ? new Date(documentDate) : new Date());
    request.input('p_LocaCode', sql.VarChar(5), finalLocaCode);
    request.input('p_ManualNo', sql.VarChar(20), (manualNo || '').substring(0, 15));
    request.input('p_Reference', sql.VarChar(30), (reference || '').substring(0, 30));
    request.input('p_DeliveryTerms', sql.VarChar(20), (deliveryTerms || '').substring(0, 15));
    request.input('p_PaymentTerms', sql.VarChar(100), (paymentTerms || '').substring(0, 50));
    request.input('p_Remarks', sql.VarChar(300), (remarks || '').substring(0, 100));
    request.input('p_CreditPeriod', sql.Int, creditPeriod || 0);
    request.input('p_GrossAmount', sql.Decimal(10, 3), grossAmount || 0);
    request.input('p_DiscPer', sql.Decimal(10, 3), discPer || 0);
    request.input('p_DiscAmount', sql.Decimal(10, 3), discAmount || 0);
    request.input('p_TaxPer', sql.Decimal(10, 3), taxPer || 0);
    request.input('p_TaxAmount', sql.Decimal(10, 3), taxAmount || 0);
    request.input('p_NetAmount', sql.Decimal(10, 3), netAmount || grossAmount || 0);
    request.input('p_LedgerCode1', sql.VarChar(15), (ledgerCode1 || '').substring(0, 15));
    request.input('p_DoubleEntery1', sql.VarChar(5), (doubleEntery1 || '').substring(0, 5));
    request.input('p_LedgerCode2', sql.VarChar(15), (ledgerCode2 || '').substring(0, 15));
    request.input('p_LedgerCode3', sql.VarChar(15), (ledgerCode3 || '').substring(0, 15));
    request.input('p_DoubleEntery2', sql.VarChar(5), (doubleEntery2 || '').substring(0, 5));
    request.input('p_DoubleEntery3', sql.VarChar(5), (doubleEntery3 || '').substring(0, 5));
    request.input('p_CostCenter', sql.VarChar(10), finalCostCenter);
    request.input('p_JobNumber', sql.VarChar(10), (jobNumber || '').substring(0, 10));
    request.input('p_OtherCharge', sql.Decimal(10, 3), otherCharge || 0);
    request.input('p_Recall', sql.Bit, recall ? 1 : 0);
    request.input('p_QuoRecall', sql.Bit, quoRecall ? 1 : 0);
    request.input('p_SonRecall', sql.Bit, sonRecall ? 1 : 0);
    request.input('p_DisRecall', sql.Bit, disRecall ? 1 : 0);
    request.input('p_ToDispach', sql.Bit, toDispach ? 1 : 0);
    request.input('p_SaveDocNo', sql.VarChar(20), (saveDocNo || '').substring(0, 20));
    request.input('p_SalesType', sql.VarChar(20), (salesType || '').substring(0, 10));
    request.input('p_PriceLevel', sql.VarChar(15), (priceLevel || '').substring(0, 10));
    request.input('p_Quotation', sql.VarChar(20), (quotation || '').substring(0, 15));
    request.input('p_Performer', sql.VarChar(20), (performer || '').substring(0, 15));
    request.input('p_Dispatch', sql.VarChar(20), (dispatch || '').substring(0, 15));
    request.input('p_TempCreditAmt', sql.Decimal(10, 3), tempCreditAmt || 0);
    request.input('p_RoudAmt', sql.Decimal(10, 3), roudAmt || 0);
    request.input('p_PODate', sql.DateTime, poDate ? new Date(poDate) : null);
    request.input('p_Currancy', sql.VarChar(20), (currancy || 'LKR').substring(0, 3));
    request.input('p_User_Name', sql.VarChar(50), (user_Name || '').substring(0, 15));

    // Execute stored procedure with trace flag to show truncation details (SQL 8152)
    console.log(`📋 Executing stored procedure: inv_USp_InvoicePostProcess`);
    console.log(`📋 Key parameters: TempDocNo=${tempDocNo}, Customer=${customerCode}, Amount=${netAmount}`);

    const execSql = `
      BEGIN TRY
        DBCC TRACEON(460);
        EXEC inv_USp_InvoicePostProcess
          @p_DocAction=@p_DocAction,
          @p_CustomerCode=@p_CustomerCode,
          @p_CustomerName=@p_CustomerName,
          @p_SalesmanCode=@p_SalesmanCode,
          @p_Address=@p_Address,
          @p_Iid=@p_Iid,
          @p_TempDocNo=@p_TempDocNo,
          @p_OrgDocNo=@p_OrgDocNo,
          @p_TourCode=@p_TourCode,
          @p_DocumentDate=@p_DocumentDate,
          @p_LocaCode=@p_LocaCode,
          @p_ManualNo=@p_ManualNo,
          @p_Reference=@p_Reference,
          @p_DeliveryTerms=@p_DeliveryTerms,
          @p_PaymentTerms=@p_PaymentTerms,
          @p_Remarks=@p_Remarks,
          @p_CreditPeriod=@p_CreditPeriod,
          @p_GrossAmount=@p_GrossAmount,
          @p_DiscPer=@p_DiscPer,
          @p_DiscAmount=@p_DiscAmount,
          @p_TaxPer=@p_TaxPer,
          @p_TaxAmount=@p_TaxAmount,
          @p_NetAmount=@p_NetAmount,
          @p_LedgerCode1=@p_LedgerCode1,
          @p_DoubleEntery1=@p_DoubleEntery1,
          @p_LedgerCode2=@p_LedgerCode2,
          @p_LedgerCode3=@p_LedgerCode3,
          @p_DoubleEntery2=@p_DoubleEntery2,
          @p_DoubleEntery3=@p_DoubleEntery3,
          @p_CostCenter=@p_CostCenter,
          @p_JobNumber=@p_JobNumber,
          @p_OtherCharge=@p_OtherCharge,
          @p_Recall=@p_Recall,
          @p_QuoRecall=@p_QuoRecall,
          @p_SonRecall=@p_SonRecall,
          @p_DisRecall=@p_DisRecall,
          @p_ToDispach=@p_ToDispach,
          @p_SaveDocNo=@p_SaveDocNo,
          @p_SalesType=@p_SalesType,
          @p_PriceLevel=@p_PriceLevel,
          @p_Quotation=@p_Quotation,
          @p_Performer=@p_Performer,
          @p_Dispatch=@p_Dispatch,
          @p_TempCreditAmt=@p_TempCreditAmt,
          @p_RoudAmt=@p_RoudAmt,
          @p_PODate=@p_PODate,
          @p_Currancy=@p_Currancy,
          @p_User_Name=@p_User_Name;
        DBCC TRACEOFF(460);
      END TRY
      BEGIN CATCH
        DBCC TRACEOFF(460);
        THROW;
      END CATCH
    `;

      const result = await request.query(execSql);

      await new sql.Request(transaction)
        .input('transactionId', sql.VarChar(5), finalIid)
        .input('locaCode', sql.VarChar(5), finalLocaCode)
        .input('costCenter', sql.VarChar(10), finalCostCenter)
        .query(`
          UPDATE gen_documentno
          SET tmpdocumentno = tmpdocumentno + 1
          WHERE TransactionId = @transactionId
            AND LocaCode = @locaCode
            AND Costcenter = @costCenter
        `);

      await transaction.commit();

      console.log(`✅ Invoice ${docAction === 'P' ? 'posted' : 'saved'} successfully: ${generatedOrgDocNo}`);
      console.log(`📊 Stored procedure result:`, JSON.stringify(result, null, 2));

      res.json({
        success: true,
        message: `Invoice ${docAction === 'P' ? 'posted' : 'saved'} successfully`,
        documentNo: generatedOrgDocNo,
        tempDocNo: tempDocNo
      });
    } catch (postErr) {
      await transaction.rollback().catch(() => {});
      throw postErr;
    }

  } catch (err) {
    console.error('❌ Error posting invoice:', err);
    console.error('❌ Error name:', err.name);
    console.error('❌ Error message:', err.message);
    console.error('❌ Error stack:', err.stack);
    console.error('❌ Full error object:', JSON.stringify(err, Object.getOwnPropertyNames(err)));
    const originalMessage = err.originalError && err.originalError.message ? err.originalError.message : '';
    const preceding = Array.isArray(err.precedingErrors)
      ? err.precedingErrors.map(e => e && e.message).filter(Boolean).join(' | ')
      : '';
    const combinedDetails = [err.message, originalMessage, preceding].filter(Boolean).join(' | ');
    res.status(500).json({
      success: false,
      error: 'Failed to post invoice',
      details: combinedDetails,
      errorCode: err.code,
      errorNumber: err.number
    });
  }
});

// Diagnostic: list stored procedure parameters to help debug mismatches
app.get('/api/invoice/post/parameters', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }
    const spName = 'inv_USp_InvoicePostProcess';
    const result = await pool.request()
      .input('spName', sql.NVarChar(200), spName)
      .query(`
        SELECT 
          p.parameter_id,
          p.name,
          TYPE_NAME(p.user_type_id) AS type_name,
          p.max_length,
          p.precision,
          p.scale,
          p.is_output
        FROM sys.parameters p
        WHERE p.object_id = OBJECT_ID(@spName)
        ORDER BY p.parameter_id
      `);
    res.json({ success: true, procedure: spName, parameters: result.recordset });
  } catch (err) {
    res.status(500).json({ success: false, error: 'Failed to read parameters', details: err.message });
  }
});

// Graceful shutdown
process.on('SIGINT', async () => {
  console.log('🔄 Shutting down server...');
  if (pool) {
    await pool.close();
    console.log('🔌 Database connection closed');
  }
  process.exit(0);
});

// ==================== LOCATION TRACKING ====================

// Update user location
app.post('/api/location/update', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const {
      userCode,
      userName,
      latitude,
      longitude,
      accuracy,
      timestamp,
      speed,
      heading,
      address = '',
      manualCheckIn = false,
    } = req.body;

    console.log(`📍 Location update for ${userName} (${userCode})`);

    if (!userCode || !Number.isFinite(Number(latitude)) || !Number.isFinite(Number(longitude))) {
      return res.status(400).json({ error: 'userCode, latitude, and longitude are required' });
    }

    const userCheck = await pool.request()
      .input('userCode', sql.NVarChar, userCode)
      .query(`
        SELECT SalesmanCode, SalesmanName, ISNULL(isSuper, 0) AS isSuper
        FROM gen_salesman
        WHERE SalesmanCode = @userCode
      `);

    if (userCheck.recordset.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }

    if (userCheck.recordset[0].isSuper === 1 || userCheck.recordset[0].isSuper === true) {
      return res.status(403).json({ error: 'Super admin location tracking is not allowed' });
    }

    const parsedLatitude = Number(latitude);
    const parsedLongitude = Number(longitude);
    const isManualCheckIn =
      manualCheckIn === true || manualCheckIn === 1 || manualCheckIn === '1';
    if (
      !isManualCheckIn &&
      shouldSkipLocationUpdate(userCode, parsedLatitude, parsedLongitude)
    ) {
      return res.json({ success: true, message: 'Location update skipped (recent duplicate)' });
    }

    const cleanAddress = (address || '').toString().trim().substring(0, 255);
    const locationLabel =
      cleanAddress ||
      `${parsedLatitude.toFixed(6)},${parsedLongitude.toFixed(6)}`;
    const resolvedTimestamp = timestamp ? new Date(timestamp) : new Date();
    const dbSalesmanName =
      userCheck.recordset[0].SalesmanName?.toString().trim() || userName;

    await upsertUserLiveLocation({
      userCode,
      userName: dbSalesmanName || userName,
      latitude: parsedLatitude,
      longitude: parsedLongitude,
      accuracy: accuracy || 0,
      speed: speed || 0,
      heading: heading || 0,
      address: locationLabel,
      timestamp: resolvedTimestamp,
    });

    let checkInId = null;
    if (isManualCheckIn) {
      const checkIn = await insertSalesmanPlaceCheckIn({
        salesmanCode: userCode,
        salesmanName: dbSalesmanName || userName,
        placeName: locationLabel.substring(0, 100),
        latitude: parsedLatitude,
        longitude: parsedLongitude,
        accuracy: accuracy || 0,
        checkedInAt: resolvedTimestamp,
      });
      checkInId = checkIn.id ?? null;
      console.log(
        `📍 Manual place check-in saved for ${dbSalesmanName} (${userCode})`,
      );
    }

    console.log(`✅ Location updated for ${userName}: ${latitude}, ${longitude}`);

    res.json({
      success: true,
      message: isManualCheckIn
        ? 'Location and place check-in saved successfully'
        : 'Location updated successfully',
      checkInId,
    });

  } catch (err) {
    console.error('❌ Error updating location:', err);
    res.status(500).json({ error: 'Failed to update location', details: err.message });
  }
});

// Salesman place check-in history (for backdate reporting)
app.get('/api/salesman-place-checkin', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const salesmanCode = (req.query.salesmanCode || '').toString().trim().substring(0, 15);
    const dateParam = (req.query.date || '').toString().trim();
    const fromDateParam = (req.query.fromDate || req.query.from || '').toString().trim();
    const toDateParam = (req.query.toDate || req.query.to || '').toString().trim();

    if (!salesmanCode) {
      return res.status(400).json({
        success: false,
        error: 'salesmanCode is required',
      });
    }

    const datePattern = /^\d{4}-\d{2}-\d{2}$/;
    if (dateParam && !datePattern.test(dateParam)) {
      return res.status(400).json({
        success: false,
        error: 'date must be YYYY-MM-DD',
      });
    }
    if (fromDateParam && !datePattern.test(fromDateParam)) {
      return res.status(400).json({
        success: false,
        error: 'fromDate must be YYYY-MM-DD',
      });
    }
    if (toDateParam && !datePattern.test(toDateParam)) {
      return res.status(400).json({
        success: false,
        error: 'toDate must be YYYY-MM-DD',
      });
    }

    await ensureSalesmanPlaceCheckInTable();

    const request = pool.request().input('salesmanCode', sql.NVarChar(15), salesmanCode);

    let dateFilter = '';
    if (dateParam) {
      request.input('targetDate', sql.Date, dateParam);
      dateFilter = 'AND CAST(CheckedInAt AS DATE) = @targetDate';
    } else if (fromDateParam && toDateParam) {
      request.input('fromDate', sql.Date, fromDateParam);
      request.input('toDate', sql.Date, toDateParam);
      dateFilter =
        'AND CAST(CheckedInAt AS DATE) >= @fromDate AND CAST(CheckedInAt AS DATE) <= @toDate';
    } else if (fromDateParam) {
      request.input('fromDate', sql.Date, fromDateParam);
      dateFilter = 'AND CAST(CheckedInAt AS DATE) >= @fromDate';
    } else if (toDateParam) {
      request.input('toDate', sql.Date, toDateParam);
      dateFilter = 'AND CAST(CheckedInAt AS DATE) <= @toDate';
    }

    const result = await request.query(`
      SELECT
        id,
        SalesmanCode AS salesmanCode,
        SalesmanName AS salesmanName,
        PlaceName AS placeName,
        Latitude AS latitude,
        Longitude AS longitude,
        Accuracy AS accuracy,
        Remarks AS remarks,
        CheckedInAt AS checkedInAt
      FROM gen_salesmanPlaceCheckIn
      WHERE SalesmanCode = @salesmanCode
        ${dateFilter}
      ORDER BY CheckedInAt DESC
    `);

    res.json({
      success: true,
      entries: result.recordset,
    });
  } catch (err) {
    console.error('❌ Error loading salesman place check-ins:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load place check-ins',
      details: err.message,
    });
  }
});

// Admin salesman location check-in history (gen_salesmanPlaceCheckIn)
app.get('/api/admin-history/location-checkins', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const salesmanCode = (req.query.salesmanCode || '').toString().trim().substring(0, 15);
    const fromDateParam = (req.query.fromDate || req.query.from || '').toString().trim();
    const toDateParam = (req.query.toDate || req.query.to || '').toString().trim();

    const datePattern = /^\d{4}-\d{2}-\d{2}$/;
    if (fromDateParam && !datePattern.test(fromDateParam)) {
      return res.status(400).json({
        success: false,
        error: 'fromDate must be YYYY-MM-DD',
      });
    }
    if (toDateParam && !datePattern.test(toDateParam)) {
      return res.status(400).json({
        success: false,
        error: 'toDate must be YYYY-MM-DD',
      });
    }

    console.log(
      '📍 Fetching admin salesman location history from gen_salesmanPlaceCheckIn' +
      (salesmanCode ? ` for ${salesmanCode}` : ' (all salesmen)'),
    );

    await ensureSalesmanPlaceCheckInTable();

    const request = pool.request();
    let salesmanFilter = '';
    if (salesmanCode) {
      request.input('salesmanCode', sql.NVarChar(15), salesmanCode);
      salesmanFilter =
        "AND LTRIM(RTRIM(p.SalesmanCode)) = LTRIM(RTRIM(@salesmanCode))";
    }

    let dateFilter = '';
    if (fromDateParam && toDateParam) {
      request.input('fromDate', sql.Date, fromDateParam);
      request.input('toDate', sql.Date, toDateParam);
      dateFilter =
        'AND CAST(p.CheckedInAt AS DATE) >= @fromDate AND CAST(p.CheckedInAt AS DATE) <= @toDate';
    } else if (fromDateParam) {
      request.input('fromDate', sql.Date, fromDateParam);
      dateFilter = 'AND CAST(p.CheckedInAt AS DATE) >= @fromDate';
    } else if (toDateParam) {
      request.input('toDate', sql.Date, toDateParam);
      dateFilter = 'AND CAST(p.CheckedInAt AS DATE) <= @toDate';
    }

    const result = await request.query(`
      SELECT
        p.id,
        LTRIM(RTRIM(p.SalesmanCode)) AS salesmanCode,
        ISNULL(s.SalesmanName, p.SalesmanName) AS salesmanName,
        ISNULL(p.PlaceName, '') AS placeName,
        p.Latitude AS latitude,
        p.Longitude AS longitude,
        p.Accuracy AS accuracy,
        ISNULL(p.Remarks, '') AS remarks,
        p.CheckedInAt AS checkedInAt
      FROM gen_salesmanPlaceCheckIn p
      LEFT JOIN gen_salesman s
        ON LTRIM(RTRIM(s.SalesmanCode)) = LTRIM(RTRIM(p.SalesmanCode))
      WHERE LTRIM(RTRIM(ISNULL(p.SalesmanCode, ''))) <> ''
        ${salesmanFilter}
        ${dateFilter}
      ORDER BY p.CheckedInAt ASC
    `);

    console.log(`✅ Loaded ${result.recordset.length} salesman location history point(s)`);

    res.json({
      success: true,
      salesmanCode: salesmanCode || null,
      entries: result.recordset,
    });
  } catch (err) {
    console.error('❌ Error loading admin location check-ins:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load salesman location history',
      details: err.message,
    });
  }
});

const REP_HISTORY_DOCUMENT_TYPES = {
  invoice: 'INV',
  'sales-order': 'SON',
  quotation: 'QUO',
  crn: 'CRN',
};

// Rep document history (invoices, sales orders, quotations, CRN)
app.get('/api/rep-history/documents', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const salesmanCode = (req.query.salesmanCode || '').toString().trim().substring(0, 15);
    const documentType = (req.query.type || req.query.documentType || '')
      .toString()
      .trim()
      .toLowerCase();
    const fromDateParam = (req.query.fromDate || req.query.from || '').toString().trim();
    const toDateParam = (req.query.toDate || req.query.to || '').toString().trim();
    const limitParam = Number.parseInt((req.query.limit || '100').toString(), 10);
    const limit = Number.isFinite(limitParam)
      ? Math.min(Math.max(limitParam, 1), 500)
      : 100;
    const iid = REP_HISTORY_DOCUMENT_TYPES[documentType];

    if (!salesmanCode) {
      return res.status(400).json({
        success: false,
        error: 'salesmanCode is required',
      });
    }

    if (!iid) {
      return res.status(400).json({
        success: false,
        error: 'type must be invoice, sales-order, quotation, or crn',
      });
    }

    const datePattern = /^\d{4}-\d{2}-\d{2}$/;
    if (fromDateParam && !datePattern.test(fromDateParam)) {
      return res.status(400).json({
        success: false,
        error: 'fromDate must be YYYY-MM-DD',
      });
    }
    if (toDateParam && !datePattern.test(toDateParam)) {
      return res.status(400).json({
        success: false,
        error: 'toDate must be YYYY-MM-DD',
      });
    }

    const request = pool.request()
      .input('salesmanCode', sql.NVarChar(15), salesmanCode)
      .input('iid', sql.VarChar(3), iid)
      .input('limit', sql.Int, limit);

    let dateFilter = '';
    if (fromDateParam && toDateParam) {
      request.input('fromDate', sql.Date, fromDateParam);
      request.input('toDate', sql.Date, toDateParam);
      dateFilter =
        'AND CAST(h.DocumentDate AS DATE) >= @fromDate AND CAST(h.DocumentDate AS DATE) <= @toDate';
    } else if (fromDateParam) {
      request.input('fromDate', sql.Date, fromDateParam);
      dateFilter = 'AND CAST(h.DocumentDate AS DATE) >= @fromDate';
    } else if (toDateParam) {
      request.input('toDate', sql.Date, toDateParam);
      dateFilter = 'AND CAST(h.DocumentDate AS DATE) <= @toDate';
    }

    const result = await request.query(`
      SELECT TOP (@limit)
        h.DocumentNo AS documentNo,
        CONVERT(varchar(10), h.DocumentDate, 120) AS documentDate,
        h.CustomerCode AS customerCode,
        ISNULL(c.CustomerName, h.CustomerCode) AS customerName,
        ISNULL(h.NetAmount, 0) AS netAmount,
        ISNULL(h.BalanceAmount, 0) AS balanceAmount,
        ISNULL(h.Remarks, '') AS remarks,
        h.Iid AS documentType
      FROM inv_invoiceheader h
      LEFT JOIN gen_customer c ON c.CustomerCode = h.CustomerCode
      WHERE h.Iid = @iid
        AND h.StatusId = 1
        AND LTRIM(RTRIM(ISNULL(h.SalesmanCode, ''))) = @salesmanCode
        ${dateFilter}
      ORDER BY h.DocumentDate DESC, h.DocumentNo DESC
    `);

    res.json({
      success: true,
      documentType,
      entries: result.recordset,
    });
  } catch (err) {
    console.error('❌ Error loading rep document history:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load document history',
      details: err.message,
    });
  }
});

// Admin document history — all data from inv_invoiceheader + gen_salesman + gen_customer
app.get('/api/admin-history/salesmen', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    console.log('📋 Fetching salesmen for admin Sales & History filter from gen_salesman...');

    const result = await pool.request().query(`
      SELECT
        LTRIM(RTRIM(SalesmanCode)) AS salesmanCode,
        ISNULL(SalesmanName, LTRIM(RTRIM(SalesmanCode))) AS salesmanName
      FROM gen_salesman
      WHERE (BlackListed = 0 OR BlackListed IS NULL)
        AND (Suspend = 0 OR Suspend IS NULL)
        AND ISNULL(isAdmin, 0) = 0
        AND ISNULL(isSuper, 0) = 0
        AND LTRIM(RTRIM(ISNULL(SalesmanCode, ''))) <> ''
      ORDER BY SalesmanName, SalesmanCode
    `);

    console.log(`✅ Loaded ${result.recordset.length} salesmen for admin history filter`);
    res.json({ success: true, salesmen: result.recordset });
  } catch (err) {
    console.error('❌ Error loading admin history salesmen:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load salesmen for history filter',
      details: err.message,
    });
  }
});

app.get('/api/admin-history/documents', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ success: false, error: 'Database not connected' });
    }

    const salesmanCode = (req.query.salesmanCode || '').toString().trim().substring(0, 15);
    const documentType = (req.query.type || req.query.documentType || '')
      .toString()
      .trim()
      .toLowerCase();
    const fromDateParam = (req.query.fromDate || req.query.from || '').toString().trim();
    const toDateParam = (req.query.toDate || req.query.to || '').toString().trim();
    const searchQuery = (req.query.search || req.query.q || '').toString().trim();
    const limitParam = Number.parseInt((req.query.limit || '5000').toString(), 10);
    const limit = Number.isFinite(limitParam)
      ? Math.min(Math.max(limitParam, 1), 10000)
      : 5000;
    const iid = REP_HISTORY_DOCUMENT_TYPES[documentType];

    if (!iid) {
      return res.status(400).json({
        success: false,
        error: 'type must be invoice, sales-order, quotation, or crn',
      });
    }

    const datePattern = /^\d{4}-\d{2}-\d{2}$/;
    if (fromDateParam && !datePattern.test(fromDateParam)) {
      return res.status(400).json({
        success: false,
        error: 'fromDate must be YYYY-MM-DD',
      });
    }
    if (toDateParam && !datePattern.test(toDateParam)) {
      return res.status(400).json({
        success: false,
        error: 'toDate must be YYYY-MM-DD',
      });
    }

    const filterParts = [
      `type=${documentType} (${iid})`,
      salesmanCode ? `salesman=${salesmanCode}` : 'salesman=ALL',
      fromDateParam ? `from=${fromDateParam}` : null,
      toDateParam ? `to=${toDateParam}` : null,
      searchQuery ? `search="${searchQuery}"` : null,
    ].filter(Boolean);

    console.log(
      `📋 Fetching admin Sales & History documents from inv_invoiceheader [${filterParts.join(', ')}]`,
    );

    const request = pool.request()
      .input('iid', sql.VarChar(3), iid)
      .input('limit', sql.Int, limit);

    let salesmanFilter = '';
    if (salesmanCode) {
      request.input('salesmanCode', sql.NVarChar(15), salesmanCode);
      salesmanFilter =
        "AND LTRIM(RTRIM(ISNULL(h.SalesmanCode, ''))) = LTRIM(RTRIM(@salesmanCode))";
    }

    let dateFilter = '';
    if (fromDateParam && toDateParam) {
      request.input('fromDate', sql.Date, fromDateParam);
      request.input('toDate', sql.Date, toDateParam);
      dateFilter =
        'AND CAST(h.DocumentDate AS DATE) >= @fromDate AND CAST(h.DocumentDate AS DATE) <= @toDate';
    } else if (fromDateParam) {
      request.input('fromDate', sql.Date, fromDateParam);
      dateFilter = 'AND CAST(h.DocumentDate AS DATE) >= @fromDate';
    } else if (toDateParam) {
      request.input('toDate', sql.Date, toDateParam);
      dateFilter = 'AND CAST(h.DocumentDate AS DATE) <= @toDate';
    }

    let searchFilter = '';
    if (searchQuery) {
      request.input('searchQuery', sql.NVarChar(100), `%${searchQuery}%`);
      searchFilter = `
        AND (
          h.DocumentNo LIKE @searchQuery
          OR h.CustomerCode LIKE @searchQuery
          OR ISNULL(c.CustomerName, h.CustomerCode) LIKE @searchQuery
          OR LTRIM(RTRIM(ISNULL(h.SalesmanCode, ''))) LIKE @searchQuery
          OR ISNULL(s.SalesmanName, h.SalesmanCode) LIKE @searchQuery
        )`;
    }

    const baseFrom = `
      FROM inv_invoiceheader h
      LEFT JOIN gen_customer c ON c.CustomerCode = h.CustomerCode
      LEFT JOIN gen_salesman s
        ON LTRIM(RTRIM(s.SalesmanCode)) = LTRIM(RTRIM(h.SalesmanCode))
      WHERE h.Iid = @iid
        AND h.StatusId = 1
        AND LTRIM(RTRIM(ISNULL(h.SalesmanCode, ''))) <> ''
        ${salesmanFilter}
        ${dateFilter}
        ${searchFilter}
    `;

    const summaryResult = await request.query(`
      SELECT
        COUNT(*) AS documentCount,
        COUNT(DISTINCT LTRIM(RTRIM(ISNULL(h.SalesmanCode, '')))) AS salesmanCount,
        ISNULL(SUM(ISNULL(h.NetAmount, 0)), 0) AS grandTotal
      ${baseFrom}
    `);

    const groupsResult = await request.query(`
      SELECT
        LTRIM(RTRIM(ISNULL(h.SalesmanCode, ''))) AS salesmanCode,
        ISNULL(s.SalesmanName, h.SalesmanCode) AS salesmanName,
        COUNT(*) AS documentCount,
        ISNULL(SUM(ISNULL(h.NetAmount, 0)), 0) AS totalAmount
      ${baseFrom}
      GROUP BY
        LTRIM(RTRIM(ISNULL(h.SalesmanCode, ''))),
        ISNULL(s.SalesmanName, h.SalesmanCode)
      ORDER BY ISNULL(s.SalesmanName, h.SalesmanCode)
    `);

    const entriesResult = await request.query(`
      SELECT TOP (@limit)
        h.DocumentNo AS documentNo,
        CONVERT(varchar(10), h.DocumentDate, 120) AS documentDate,
        h.CustomerCode AS customerCode,
        ISNULL(c.CustomerName, h.CustomerCode) AS customerName,
        ISNULL(h.NetAmount, 0) AS netAmount,
        ISNULL(h.BalanceAmount, 0) AS balanceAmount,
        ISNULL(h.Remarks, '') AS remarks,
        h.Iid AS documentType,
        LTRIM(RTRIM(ISNULL(h.SalesmanCode, ''))) AS salesmanCode,
        ISNULL(s.SalesmanName, h.SalesmanCode) AS salesmanName
      ${baseFrom}
      ORDER BY ISNULL(s.SalesmanName, h.SalesmanCode), h.DocumentDate DESC, h.DocumentNo DESC
    `);

    const entries = entriesResult.recordset;
    const groups = groupsResult.recordset.map((group) => ({
      salesmanCode: group.salesmanCode || '',
      salesmanName: group.salesmanName || group.salesmanCode || 'Unknown',
      documentCount: group.documentCount || 0,
      totalAmount: group.totalAmount || 0,
      entries: entries.filter(
        (entry) => (entry.salesmanCode || '') === (group.salesmanCode || ''),
      ),
    }));

    const summaryRow = summaryResult.recordset[0] || {};

    console.log(
      `✅ Admin history ${documentType}: ${summaryRow.documentCount || 0} document(s), ` +
      `${summaryRow.salesmanCount || 0} salesman group(s), ` +
      `total Rs. ${summaryRow.grandTotal || 0}` +
      (salesmanCode ? ` for salesman ${salesmanCode}` : ''),
    );

    res.json({
      success: true,
      documentType,
      salesmanCode: salesmanCode || null,
      search: searchQuery || null,
      summary: {
        documentCount: summaryRow.documentCount || 0,
        salesmanCount: summaryRow.salesmanCount || 0,
        grandTotal: summaryRow.grandTotal || 0,
      },
      groups,
      entries,
    });
  } catch (err) {
    console.error('❌ Error loading admin document history:', err);
    res.status(500).json({
      success: false,
      error: 'Failed to load admin document history',
      details: err.message,
    });
  }
});

// Get all user locations (for admin)
app.get('/api/location/all', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    console.log('📍 Fetching all user locations...');

    await ensureUserLocTable();

    const result = await pool.request().query(`
      SELECT 
        ul.userCode,
        ISNULL(s.SalesmanName, ul.userName) as userName,
        ul.latitude,
        ul.longitude,
        ul.accuracy,
        ul.speed,
        ul.heading,
        ul.address,
        ul.timestamp,
        ul.updated_at,
        ul.isActive,
        ISNULL(s.SalesmanType, 'sales') as userType,
        ISNULL(s.Location, '') as locationCode,
        ISNULL(l.LocationDescription, '') as locationDescription,
        CASE 
          WHEN DATEDIFF(MINUTE, ul.timestamp, GETDATE()) <= 10 AND ul.isActive = 1 THEN 'Active'
          ELSE 'Inactive'
        END as status
      FROM gen_userLoc ul
      LEFT JOIN gen_salesman s
        ON s.SalesmanCode = ul.userCode
      LEFT JOIN gen_location l ON s.Location = l.LocationCode
      WHERE ul.latitude IS NOT NULL
        AND ul.longitude IS NOT NULL
        AND ul.latitude <> 0
        AND ul.longitude <> 0
        AND (s.SalesmanCode IS NULL OR ((s.BlackListed = 0 OR s.BlackListed IS NULL) AND (s.Suspend = 0 OR s.Suspend IS NULL)))
      ORDER BY 
        CASE WHEN DATEDIFF(MINUTE, ul.timestamp, GETDATE()) <= 10 AND ul.isActive = 1 THEN 0 ELSE 1 END,
        ul.timestamp DESC,
        ul.updated_at DESC
    `);

    console.log(`✅ Retrieved ${result.recordset.length} salesman locations from database`);
    res.json(result.recordset);

  } catch (err) {
    console.error('❌ Error fetching user locations:', err);
    res.status(500).json({ error: 'Failed to fetch user locations', details: err.message });
  }
});

// Get all user locations with user types (for super admin only)
app.get('/api/location/all-with-types', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    console.log('📍 Fetching all user locations with types (Super Admin)...');

    await ensureUserLocTable();

    const result = await pool.request().query(`
      SELECT 
        ul.userCode,
        ISNULL(s.SalesmanName, ul.userName) as userName,
        ul.latitude,
        ul.longitude,
        ul.accuracy,
        ul.speed,
        ul.heading,
        ul.address,
        ul.timestamp,
        ul.updated_at,
        ul.isActive,
        CASE 
          WHEN DATEDIFF(MINUTE, ul.timestamp, GETDATE()) <= 10 AND ul.isActive = 1 THEN 'Active'
          ELSE 'Inactive'
        END as status,
        CASE 
          WHEN ISNULL(s.isSuper, 0) = 1 THEN 'Super Admin'
          WHEN ISNULL(s.isAdmin, 0) = 1 THEN 'Admin'
          ELSE 'Salesman'
        END as userType,
        s.isAdmin,
        s.isSuper,
        ISNULL(s.SalesmanType, 'sales') as salesmanType,
        ISNULL(s.Location, '') as locationCode,
        ISNULL(l.LocationDescription, '') as locationDescription
      FROM gen_userLoc ul
      LEFT JOIN gen_salesman s
        ON s.SalesmanCode = ul.userCode
      LEFT JOIN gen_location l ON s.Location = l.LocationCode
      WHERE ul.latitude IS NOT NULL
        AND ul.longitude IS NOT NULL
        AND ul.latitude <> 0
        AND ul.longitude <> 0
        AND (s.SalesmanCode IS NULL OR ((s.BlackListed = 0 OR s.BlackListed IS NULL) AND (s.Suspend = 0 OR s.Suspend IS NULL)))
      ORDER BY 
        CASE WHEN DATEDIFF(MINUTE, ul.timestamp, GETDATE()) <= 10 AND ul.isActive = 1 THEN 0 ELSE 1 END,
        ul.timestamp DESC,
        ul.updated_at DESC
    `);

    console.log(`✅ Retrieved ${result.recordset.length} database salesman locations with types`);
    res.json(result.recordset);

  } catch (err) {
    console.error('❌ Error fetching user locations with types:', err);
    res.status(500).json({ error: 'Failed to fetch user locations with types', details: err.message });
  }
});

// Get specific user location
app.get('/api/location/user/:userCode', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const { userCode } = req.params;

    const result = await pool.request()
      .input('userCode', sql.NVarChar, userCode)
      .query(`
        SELECT 
          userCode,
          userName,
          latitude,
          longitude,
          accuracy,
          speed,
          heading,
          address,
          timestamp,
          updated_at,
          isActive,
          CASE 
            WHEN DATEDIFF(MINUTE, timestamp, GETDATE()) <= 10 AND isActive = 1 THEN 'Active'
            ELSE 'Inactive'
          END as status
        FROM gen_userLoc
        WHERE userCode = @userCode AND isActive = 1
      `);

    if (result.recordset.length === 0) {
      return res.status(404).json({ error: 'User location not found' });
    }

    res.json(result.recordset[0]);

  } catch (err) {
    console.error('❌ Error fetching user location:', err);
    res.status(500).json({ error: 'Failed to fetch user location', details: err.message });
  }
});

// Delete user location (when user logs out)
app.delete('/api/location/user/:userCode', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const { userCode } = req.params;

    await pool.request()
      .input('userCode', sql.NVarChar, userCode)
      .query(`UPDATE gen_userLoc SET isActive = 0, updated_at = GETDATE() WHERE userCode = @userCode`);

    console.log(`🗑️ Deactivated location tracking for user: ${userCode}`);

    broadcastDataChange('location_update', {
      userCode,
      status: 'Inactive',
    });

    res.json({ success: true, message: 'Location tracking deactivated' });

  } catch (err) {
    console.error('❌ Error deleting user location:', err);
    res.status(500).json({ error: 'Failed to delete user location', details: err.message });
  }
});

// ==================== DEVICE TRACKING ====================

const MAX_ALLOWED_DEVICES = 5;

async function ensureUserDeviceTable(request) {
  await request.query(`
    IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='gen_userDevice' AND xtype='U')
    CREATE TABLE gen_userDevice (
      id INT IDENTITY(1,1) PRIMARY KEY,
      deviceId NVARCHAR(100) NOT NULL,
      userCode NVARCHAR(50) NOT NULL,
      userName NVARCHAR(100) NOT NULL,
      deviceName NVARCHAR(100) NULL,
      deviceModel NVARCHAR(100) NULL,
      platform NVARCHAR(20) NULL,
      osVersion NVARCHAR(50) NULL,
      appVersion NVARCHAR(20) NULL,
      isAdmin BIT NOT NULL DEFAULT 0,
      isSuper BIT NOT NULL DEFAULT 0,
      isAllowed BIT NOT NULL DEFAULT 1,
      approvedAt DATETIME2 NULL,
      approvedBy NVARCHAR(100) NULL,
      firstSeenAt DATETIME2 NOT NULL DEFAULT GETDATE(),
      lastSeenAt DATETIME2 NOT NULL DEFAULT GETDATE(),
      isActive BIT NOT NULL DEFAULT 1,
      CONSTRAINT UQ_gen_userDevice_deviceId UNIQUE (deviceId)
    )
  `);

  await request.query(`
    IF NOT EXISTS (
      SELECT 1 FROM sys.columns
      WHERE object_id = OBJECT_ID('gen_userDevice') AND name = 'isAllowed'
    )
    ALTER TABLE gen_userDevice ADD isAllowed BIT NOT NULL CONSTRAINT DF_gen_userDevice_isAllowed DEFAULT 1;
  `);

  await request.query(`
    IF NOT EXISTS (
      SELECT 1 FROM sys.columns
      WHERE object_id = OBJECT_ID('gen_userDevice') AND name = 'approvedAt'
    )
    ALTER TABLE gen_userDevice ADD approvedAt DATETIME2 NULL;
  `);

  await request.query(`
    IF NOT EXISTS (
      SELECT 1 FROM sys.columns
      WHERE object_id = OBJECT_ID('gen_userDevice') AND name = 'approvedBy'
    )
    ALTER TABLE gen_userDevice ADD approvedBy NVARCHAR(100) NULL;
  `);
}

async function getAllowedDeviceCount() {
  const result = await pool.request().query(`
    SELECT COUNT(*) as total
    FROM gen_userDevice
    WHERE isSuper = 0
      AND isAllowed = 1
  `);
  return result.recordset[0]?.total || 0;
}

async function upsertDeviceRecord({
  deviceId,
  userCode,
  userName,
  deviceName,
  deviceModel,
  platform,
  osVersion,
  appVersion,
  isAdmin,
  isAllowed,
  approvedBy = null
}) {
  await pool.request()
    .input('deviceId', sql.NVarChar(100), deviceId)
    .input('userCode', sql.NVarChar(50), userCode)
    .input('userName', sql.NVarChar(100), userName)
    .input('deviceName', sql.NVarChar(100), deviceName)
    .input('deviceModel', sql.NVarChar(100), deviceModel)
    .input('platform', sql.NVarChar(20), platform)
    .input('osVersion', sql.NVarChar(50), osVersion)
    .input('appVersion', sql.NVarChar(20), appVersion)
    .input('isAdmin', sql.Bit, isAdmin ? 1 : 0)
    .input('isAllowed', sql.Bit, isAllowed ? 1 : 0)
    .input('approvedBy', sql.NVarChar(100), approvedBy)
    .query(`
      MERGE gen_userDevice AS target
      USING (SELECT @deviceId AS deviceId) AS source
      ON target.deviceId = source.deviceId
      WHEN MATCHED THEN
        UPDATE SET
          userCode = @userCode,
          userName = @userName,
          deviceName = @deviceName,
          deviceModel = @deviceModel,
          platform = @platform,
          osVersion = @osVersion,
          appVersion = @appVersion,
          isAdmin = @isAdmin,
          isSuper = 0,
          isAllowed = CASE
            WHEN target.isAllowed = 1 THEN 1
            ELSE @isAllowed
          END,
          approvedAt = CASE
            WHEN target.isAllowed = 1 THEN target.approvedAt
            WHEN @isAllowed = 1 THEN GETDATE()
            ELSE target.approvedAt
          END,
          approvedBy = CASE
            WHEN target.isAllowed = 1 THEN target.approvedBy
            WHEN @isAllowed = 1 THEN @approvedBy
            ELSE target.approvedBy
          END,
          lastSeenAt = GETDATE(),
          isActive = 1
      WHEN NOT MATCHED THEN
        INSERT (
          deviceId, userCode, userName, deviceName, deviceModel, platform,
          osVersion, appVersion, isAdmin, isSuper, isAllowed,
          approvedAt, approvedBy, firstSeenAt, lastSeenAt, isActive
        )
        VALUES (
          @deviceId, @userCode, @userName, @deviceName, @deviceModel, @platform,
          @osVersion, @appVersion, @isAdmin, 0, @isAllowed,
          CASE WHEN @isAllowed = 1 THEN GETDATE() ELSE NULL END,
          @approvedBy,
          GETDATE(), GETDATE(), 1
        );
    `);
}

// Register or update an installed device
app.post('/api/devices/register', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const {
      deviceId,
      userCode,
      userName,
      deviceName = '',
      deviceModel = '',
      platform = '',
      osVersion = '',
      appVersion = '',
      isAdmin = false,
      isSuper = false
    } = req.body;

    const cleanDeviceId = (deviceId || '').toString().trim();
    const cleanUserCode = (userCode || '').toString().trim();
    const cleanUserName = (userName || '').toString().trim();

    if (!cleanDeviceId || !cleanUserCode || !cleanUserName) {
      return res.status(400).json({
        error: 'deviceId, userCode, and userName are required'
      });
    }

    if (isSuper === true || isSuper === 1) {
      return res.json({
        success: true,
        allowed: true,
        isAllowed: 1,
        message: 'Super admin devices are not tracked'
      });
    }

    const request = pool.request();
    await ensureUserDeviceTable(request);

    const existingResult = await pool.request()
      .input('deviceId', sql.NVarChar(100), cleanDeviceId.substring(0, 100))
      .query(`
        SELECT isAllowed
        FROM gen_userDevice
        WHERE deviceId = @deviceId AND isSuper = 0
      `);

    const payload = {
      deviceId: cleanDeviceId.substring(0, 100),
      userCode: cleanUserCode.substring(0, 50),
      userName: cleanUserName.substring(0, 100),
      deviceName: deviceName.toString().substring(0, 100),
      deviceModel: deviceModel.toString().substring(0, 100),
      platform: platform.toString().substring(0, 20),
      osVersion: osVersion.toString().substring(0, 50),
      appVersion: appVersion.toString().substring(0, 20),
      isAdmin: isAdmin === true || isAdmin === 1
    };

    if (existingResult.recordset.length > 0) {
      const currentAllowed = existingResult.recordset[0].isAllowed === true ||
        existingResult.recordset[0].isAllowed === 1;

      await upsertDeviceRecord({
        ...payload,
        isAllowed: currentAllowed,
        approvedBy: null
      });

      return res.json({
        success: true,
        allowed: currentAllowed,
        isAllowed: currentAllowed ? 1 : 0,
        maxAllowed: MAX_ALLOWED_DEVICES,
        message: currentAllowed
          ? 'Device allowed'
          : `Device limit reached (${MAX_ALLOWED_DEVICES}). Waiting for super admin approval.`
      });
    }

    const allowedCount = await getAllowedDeviceCount();
    const isAllowed = allowedCount < MAX_ALLOWED_DEVICES;

    await upsertDeviceRecord({
      ...payload,
      isAllowed,
      approvedBy: isAllowed ? 'auto' : null
    });

    console.log(`📱 Device registered: ${cleanUserName} (isAllowed=${isAllowed ? 1 : 0})`);

    // --- Send Email Notification for New Device ---
    try {
      const emailHtml = getNewDeviceLoginEmailHtml(
        cleanUserName,
        `${deviceName} ${deviceModel}`.trim(),
        `${platform} ${osVersion}`.trim(),
        new Date().toLocaleString()
      );
      
      await resend.emails.send({
        from: 'onboarding@resend.dev', // Replace with your verified domain
        to: 'maleeshasanjanadilshan@gmail.com', // Recipient's email address
        subject: `New Device Login Alert for ${cleanUserName}`,
        html: emailHtml,
      });
      console.log(`📧 New device login email sent successfully for ${cleanUserName}`);
    } catch (emailError) {
      console.error('❌ Failed to send new device login email:', emailError);
    }
    // ---------------------------------------------

    res.json({
      success: true,
      allowed: isAllowed,
      isAllowed: isAllowed ? 1 : 0,
      maxAllowed: MAX_ALLOWED_DEVICES,
      allowedCount: isAllowed ? allowedCount + 1 : allowedCount,
      message: isAllowed
        ? 'Device registered successfully'
        : `Device limit reached (${MAX_ALLOWED_DEVICES}). Waiting for super admin approval.`
    });
  } catch (err) {
    console.error('❌ Error registering device:', err);
    res.status(500).json({ error: 'Failed to register device', details: err.message });
  }
});

// Super admin approves a pending device
app.post('/api/devices/approve', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const { deviceId, approvedBy = '', replaceDeviceId = '' } = req.body;
    const cleanDeviceId = (deviceId || '').toString().trim();
    const cleanApprovedBy = (approvedBy || '').toString().trim().substring(0, 100);
    const cleanReplaceDeviceId = (replaceDeviceId || '').toString().trim();

    if (!cleanDeviceId) {
      return res.status(400).json({ error: 'deviceId is required' });
    }

    await ensureUserDeviceTable(pool.request());

    const deviceResult = await pool.request()
      .input('deviceId', sql.NVarChar(100), cleanDeviceId)
      .query(`
        SELECT deviceId, isAllowed, userName
        FROM gen_userDevice
        WHERE deviceId = @deviceId AND isSuper = 0
      `);

    if (deviceResult.recordset.length === 0) {
      return res.status(404).json({ error: 'Device not found' });
    }

    const allowedCount = await getAllowedDeviceCount();
    if (allowedCount >= MAX_ALLOWED_DEVICES) {
      if (!cleanReplaceDeviceId) {
        return res.status(400).json({
          error: `Maximum ${MAX_ALLOWED_DEVICES} allowed devices reached. Select a device to replace.`
        });
      }

      await pool.request()
        .input('deviceId', sql.NVarChar(100), cleanReplaceDeviceId.substring(0, 100))
        .query(`
          UPDATE gen_userDevice
          SET isAllowed = 0,
              isActive = 0,
              lastSeenAt = GETDATE()
          WHERE deviceId = @deviceId AND isSuper = 0
        `);
    }

    await pool.request()
      .input('deviceId', sql.NVarChar(100), cleanDeviceId)
      .input('approvedBy', sql.NVarChar(100), cleanApprovedBy || 'super admin')
      .query(`
        UPDATE gen_userDevice
        SET isAllowed = 1,
            approvedAt = GETDATE(),
            approvedBy = @approvedBy,
            isActive = 1,
            lastSeenAt = GETDATE()
        WHERE deviceId = @deviceId AND isSuper = 0
      `);

    console.log(`✅ Device approved: ${cleanDeviceId}`);
    res.json({ success: true, message: 'Device approved successfully' });
  } catch (err) {
    console.error('❌ Error approving device:', err);
    res.status(500).json({ error: 'Failed to approve device', details: err.message });
  }
});

// Super admin revokes a device
app.post('/api/devices/revoke', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const { deviceId, revokedBy = '' } = req.body;
    const cleanDeviceId = (deviceId || '').toString().trim();

    if (!cleanDeviceId) {
      return res.status(400).json({ error: 'deviceId is required' });
    }

    await pool.request()
      .input('deviceId', sql.NVarChar(100), cleanDeviceId.substring(0, 100))
      .query(`
        UPDATE gen_userDevice
        SET isAllowed = 0,
            isActive = 0,
            lastSeenAt = GETDATE()
        WHERE deviceId = @deviceId AND isSuper = 0
      `);

    console.log(`🚫 Device revoked: ${cleanDeviceId}`);
    res.json({ success: true, message: 'Device access revoked' });
  } catch (err) {
    console.error('❌ Error revoking device:', err);
    res.status(500).json({ error: 'Failed to revoke device', details: err.message });
  }
});

// Deactivate device on logout
app.post('/api/devices/deactivate', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const { deviceId } = req.body;
    const cleanDeviceId = (deviceId || '').toString().trim();

    if (!cleanDeviceId) {
      return res.status(400).json({ error: 'deviceId is required' });
    }

    const tableCheck = await pool.request().query(`
      SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'gen_userDevice'
    `);

    if (tableCheck.recordset.length === 0) {
      return res.json({ success: true, message: 'No device table yet' });
    }

    await pool.request()
      .input('deviceId', sql.NVarChar(100), cleanDeviceId)
      .query(`
        UPDATE gen_userDevice
        SET isActive = 0, lastSeenAt = GETDATE()
        WHERE deviceId = @deviceId
      `);

    console.log(`📱 Device deactivated: ${cleanDeviceId}`);
    res.json({ success: true, message: 'Device deactivated' });
  } catch (err) {
    console.error('❌ Error deactivating device:', err);
    res.status(500).json({ error: 'Failed to deactivate device', details: err.message });
  }
});

// Get all registered devices (super admin)
app.get('/api/devices/all', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const tableCheck = await pool.request().query(`
      SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'gen_userDevice'
    `);

    if (tableCheck.recordset.length === 0) {
      return res.json({
        maxAllowed: MAX_ALLOWED_DEVICES,
        allowedCount: 0,
        pendingCount: 0,
        devices: []
      });
    }

    await ensureUserDeviceTable(pool.request());

    const result = await pool.request().query(`
      SELECT
        d.deviceId,
        d.userCode,
        d.userName,
        d.deviceName,
        d.deviceModel,
        d.platform,
        d.osVersion,
        d.appVersion,
        d.isAdmin,
        d.isSuper,
        ISNULL(d.isAllowed, 1) as isAllowed,
        d.approvedAt,
        d.approvedBy,
        d.firstSeenAt,
        d.lastSeenAt,
        d.isActive,
        CASE
          WHEN d.isAdmin = 1 THEN 'Admin'
          ELSE 'Salesman'
        END as userType,
        CASE
          WHEN ISNULL(d.isAllowed, 1) = 0 THEN 'Not Allowed'
          WHEN d.isActive = 1 AND DATEDIFF(DAY, d.lastSeenAt, GETDATE()) <= 7 THEN 'Active'
          ELSE 'Inactive'
        END as status
      FROM gen_userDevice d
      WHERE d.isSuper = 0
      ORDER BY
        ISNULL(d.isAllowed, 1) ASC,
        d.lastSeenAt DESC
    `);

    const devices = result.recordset;
    const allowedCount = devices.filter((d) => d.isAllowed === true || d.isAllowed === 1).length;
    const pendingCount = devices.filter((d) => d.isAllowed === false || d.isAllowed === 0).length;

    console.log(`📱 Retrieved ${devices.length} registered devices`);
    res.json({
      maxAllowed: MAX_ALLOWED_DEVICES,
      allowedCount,
      pendingCount,
      devices
    });
  } catch (err) {
    console.error('❌ Error fetching devices:', err);
    res.status(500).json({ error: 'Failed to fetch devices', details: err.message });
  }
});

// Catch unhandled route errors and log to error.log (day-wise, single file).
app.use((err, req, res, next) => {
  console.error(
    `❌ Unhandled HTTP error: ${req.method} ${req.originalUrl}`,
    err,
  );

  if (res.headersSent) {
    return next(err);
  }

  res.status(500).json({
    error: 'Internal server error',
    details: err.message,
  });
});
