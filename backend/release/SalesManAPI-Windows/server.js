const express = require('express');
const cors = require('cors');
const compression = require('compression');
const sql = require('mssql');
const runtime = require('./runtime');
const config = runtime.loadConfig();
const http = require('http');
const WebSocket = require('ws');
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
  return text.length > 0 ? text : null;
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

// Lazy-load a single product image for item pickers
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

    const result = await pool.request()
      .input('productCode', sql.NVarChar(50), productCode)
      .query(`
        SELECT ProductImage
        FROM inv_productmaster
        WHERE ProductCode = @productCode
      `);

    if (result.recordset.length === 0) {
      return res.status(404).json({ error: 'Product not found' });
    }

    const payload = {
      productCode,
      image: encodeProductImage(result.recordset[0].ProductImage),
    };

    setCachedResponse(cacheKey, payload);
    res.set('Cache-Control', 'private, max-age=86400');
    res.json(payload);
  } catch (err) {
    console.error('Error fetching product image:', err);
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
    salesman.isAdmin = salesman.isAdmin === true || salesman.isAdmin === 1;
    salesman.isSuper = salesman.isSuper === true || salesman.isSuper === 1;
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
    salesman.isAdmin = salesman.isAdmin === true || salesman.isAdmin === 1;
    salesman.isSuper = salesman.isSuper === true || salesman.isSuper === 1;
    salesman.SalesmanType = salesman.isAdmin ? 'admin' : (salesman.SalesmanType || 'sales');

    console.log(`✅ Password authentication successful for: ${salesman.SalesmanName}`);
    console.log(`🔍 Debug - isAdmin: ${salesman.isAdmin}, isSuper: ${salesman.isSuper}`);

    res.json({ success: true, salesman: sanitizeSalesmanRecord(salesman) });
  } catch (err) {
    console.error('Error authenticating with password:', err);
    res.status(500).json({ success: false, message: 'Authentication failed', error: err.message });
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

// Lightweight customer list for sales screens (picker)
app.get('/api/customers/list', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const salesRepCode = (req.query.salesRepCode || '').toString().trim();
    const cacheKey = `customers:list:${salesRepCode || 'all'}`;
    const cached = getCachedResponse(cacheKey);
    if (cached) {
      res.set('Cache-Control', 'private, max-age=120');
      return res.json(cached);
    }

    console.log(`🔄 Fetching customer list (${salesRepCode || 'all'})...`);
    const result = await pool.request()
      .input('salesRepCode', sql.NVarChar, salesRepCode)
      .query(`
        SELECT
          CustomerCode as code,
          ISNULL(CustomerName, '') as name,
          ISNULL(Mobile, '') as phone,
          ISNULL(Address1, '') as address,
          ISNULL(SalesRepCode, '') as salesRepCode,
          ISNULL(PriceLevel, '') as priceLevel,
          ISNULL(Balance, 0) as balance,
          ISNULL(CreditLimit, 0) as creditLimit
        FROM gen_customer
        WHERE (Suspend = 0 OR Suspend IS NULL)
          AND (BlackListed = 0 OR BlackListed IS NULL)
          AND (@salesRepCode = '' OR SalesRepCode = @salesRepCode)
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

// Search customers from gen_customer by customer code or name
app.get('/api/customers/search', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }

    const { q } = req.query;
    const searchTerm = (q || '').toString().trim();

    if (!searchTerm) {
      return res.status(400).json({ error: 'Search query is required' });
    }

    const result = await pool.request()
      .input('searchTerm', sql.NVarChar(80), `%${searchTerm}%`)
      .query(`
        SELECT TOP 25
          CustomerCode as code,
          ISNULL(CustomerName, '') as name,
          ISNULL(Mobile, '') as phone,
          ISNULL(Address1, '') as address1,
          ISNULL(Address2, '') as address2,
          ISNULL(Address3, '') as address3,
          ISNULL(CustomerType, '') as customerType,
          ISNULL(TaxGroupCode, '') as taxGroupCode,
          ISNULL(Location, '') as location,
          ISNULL(CostCenter, '') as costCenter,
          ISNULL(SalesRepCode, '') as salesRepCode,
          ISNULL(ContactPerson, '') as contactPerson,
          ISNULL(CompanyName, '') as companyName,
          ISNULL(Latitude, 0) as latitude,
          ISNULL(Longitude, 0) as longitude,
          Created_Date as createdDate
        FROM gen_customer
        WHERE (Suspend = 0 OR Suspend IS NULL)
          AND (BlackListed = 0 OR BlackListed IS NULL)
          AND (
            CustomerCode LIKE @searchTerm
            OR CustomerName LIKE @searchTerm
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
      address1 = '',
      address2 = '',
      address3 = '',
      customerType = 'Trade',
      taxGroupCode = '1',
      contactPerson = '',
      companyName = '',
      salesRepCode = '',
      costCenter = '000001',
      createdUser = '',
      latitude,
      longitude
    } = req.body;

    const cleanName = (customerName || '').toString().trim();
    const cleanLocation = (location || '').toString().trim();
    const cleanCustomerType = (customerType || 'Trade').toString().trim().substring(0, 10);
    const cleanTaxGroupCode = (taxGroupCode || '1').toString().trim().substring(0, 15);
    const parsedLatitude = Number(latitude);
    const parsedLongitude = Number(longitude);

    if (!cleanName || !cleanLocation) {
      return res.status(400).json({
        success: false,
        error: 'Customer name and location are required'
      });
    }

    if (!Number.isFinite(parsedLatitude) || !Number.isFinite(parsedLongitude)) {
      return res.status(400).json({
        success: false,
        error: 'Latitude and longitude are required'
      });
    }

    transaction = new sql.Transaction(pool);
    await transaction.begin();
    transactionStarted = true;

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
      .input('customerId', sql.NVarChar(10), '')
      .input('groupCode', sql.NVarChar(15), '')
      .input('areaCode', sql.NVarChar(15), '')
      .input('territoryCode', sql.NVarChar(15), '')
      .input('rootCode', sql.NVarChar(15), '')
      .input('salesRepCode', sql.NVarChar(15), salesRepCode.toString().substring(0, 15))
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
      .input('mobile', sql.NVarChar(50), mobile.toString().substring(0, 50))
      .input('fax', sql.NVarChar(50), '')
      .input('email', sql.NVarChar(50), '')
      .input('creditLimit', sql.Decimal(18, 0), 0)
      .input('temporaryCredit', sql.Decimal(18, 0), 0)
      .input('creditPeriod', sql.Decimal(18, 0), 0)
      .input('balance', sql.Decimal(18, 2), 0)
      .input('priceLevel', sql.NVarChar(20), '')
      .input('fixedDiscount', sql.Decimal(18, 0), 0)
      .input('paymentType', sql.NVarChar(10), '')
      .input('blackListed', sql.Int, 0)
      .input('suspend', sql.Int, 0)
      .input('webSite', sql.NVarChar(50), '')
      .input('disForEarlySettlement', sql.Decimal(18, 0), 0)
      .input('location', sql.NVarChar(50), cleanLocation.substring(0, 50))
      .input('showLocation', sql.Int, 1)
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
      .input('latitude', sql.Decimal(10, 8), parsedLatitude)
      .input('longitude', sql.Decimal(11, 8), parsedLongitude)
      .query(`
        INSERT INTO gen_customer (
          CustomerCode, CustomerName, CustomerTitle, CustomerType, CustomerId,
          GroupCode, AreaCode, TerritoryCode, RootCode, SalesRepCode,
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
          @groupCode, @areaCode, @territoryCode, @rootCode, @salesRepCode,
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

    await transaction.commit();
    transactionStarted = false;
    invalidateCustomerCaches();

    const customer = {
      code: customerCode,
      name: cleanName.substring(0, 50),
      phone: mobile.toString().substring(0, 50),
      mobile: mobile.toString().substring(0, 50),
      address: address1.toString().substring(0, 70),
      address1: address1.toString().substring(0, 70),
      address2: address2.toString().substring(0, 70),
      address3: address3.toString().substring(0, 70),
      customerType: cleanCustomerType,
      taxGroupCode: cleanTaxGroupCode,
      location: cleanLocation.substring(0, 50),
      costCenter: costCenter.toString().substring(0, 15),
      salesRepCode: salesRepCode.toString().substring(0, 15),
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
      address1 = '',
      customerType = 'Trade',
      taxGroupCode = '1',
      salesRepCode = '',
      editedUser = '',
      latitude,
      longitude
    } = req.body;

    const cleanCode = (customerCode || '').toString().trim();
    const cleanName = (customerName || '').toString().trim();
    const cleanLocation = (location || '').toString().trim();
    const cleanCustomerType = (customerType || 'Trade').toString().trim().substring(0, 10);
    const cleanTaxGroupCode = (taxGroupCode || '1').toString().trim().substring(0, 15);
    const parsedLatitude = Number(latitude);
    const parsedLongitude = Number(longitude);

    if (!cleanCode) {
      return res.status(400).json({
        success: false,
        error: 'Customer code is required'
      });
    }

    if (!cleanName || !cleanLocation) {
      return res.status(400).json({
        success: false,
        error: 'Customer name and location are required'
      });
    }

    if (!Number.isFinite(parsedLatitude) || !Number.isFinite(parsedLongitude)) {
      return res.status(400).json({
        success: false,
        error: 'Latitude and longitude are required'
      });
    }

    const result = await pool.request()
      .input('customerCode', sql.NVarChar(15), cleanCode.substring(0, 15))
      .input('customerName', sql.NVarChar(50), cleanName.substring(0, 50))
      .input('payeeName', sql.NVarChar(50), cleanName.substring(0, 50))
      .input('address1', sql.NVarChar(70), address1.toString().substring(0, 70))
      .input('mobile', sql.NVarChar(50), mobile.toString().substring(0, 50))
      .input('customerType', sql.NVarChar(10), cleanCustomerType)
      .input('taxGroupCode', sql.NVarChar(15), cleanTaxGroupCode)
      .input('location', sql.NVarChar(50), cleanLocation.substring(0, 50))
      .input('salesRepCode', sql.NVarChar(15), salesRepCode.toString().substring(0, 15))
      .input('editedDate', sql.DateTime, new Date())
      .input('editedUser', sql.NChar(20), editedUser.toString().substring(0, 20))
      .input('latitude', sql.Decimal(10, 8), parsedLatitude)
      .input('longitude', sql.Decimal(11, 8), parsedLongitude)
      .query(`
        UPDATE gen_customer
        SET CustomerName = @customerName,
            PayeeName = @payeeName,
            Address1 = @address1,
            Mobile = @mobile,
            CustomerType = @customerType,
            TaxGroupCode = @taxGroupCode,
            Location = @location,
            SalesRepCode = @salesRepCode,
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

    const customer = {
      code: cleanCode.substring(0, 15),
      name: cleanName.substring(0, 50),
      mobile: mobile.toString().substring(0, 50),
      address: address1.toString().substring(0, 70),
      address1: address1.toString().substring(0, 70),
      customerType: cleanCustomerType,
      taxGroupCode: cleanTaxGroupCode,
      location: cleanLocation.substring(0, 50),
      salesRepCode: salesRepCode.toString().substring(0, 15),
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

// Get all salesmen
app.get('/api/salesmen', async (req, res) => {
  try {
    if (!pool) {
      return res.status(503).json({ error: 'Database not connected' });
    }
    
    const result = await pool.request().query(`
      SELECT 
        SalesmanCode as id,
        SalesmanName as name,
        Email as email,
        SalesmanType as role,
        Location as location,
        CASE WHEN BlackListed = 0 AND Suspend = 0 THEN 1 ELSE 0 END as is_active,
        Created_Date as created_at
      FROM gen_salesman 
      WHERE (BlackListed = 0 OR BlackListed IS NULL)
      AND (Suspend = 0 OR Suspend IS NULL)
      ORDER BY SalesmanName
    `);
    res.json(result.recordset);
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

// Start server
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
      heading
    } = req.body;

    console.log(`📍 Location update for ${userName} (${userCode})`);

    if (!userCode || !Number.isFinite(Number(latitude)) || !Number.isFinite(Number(longitude))) {
      return res.status(400).json({ error: 'userCode, latitude, and longitude are required' });
    }

    const userCheck = await pool.request()
      .input('userCode', sql.NVarChar, userCode)
      .query(`
        SELECT SalesmanCode, ISNULL(isSuper, 0) AS isSuper
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
    if (shouldSkipLocationUpdate(userCode, parsedLatitude, parsedLongitude)) {
      return res.json({ success: true, message: 'Location update skipped (recent duplicate)' });
    }

    await ensureUserLocTable();

    await pool.request()
      .input('userCode', sql.NVarChar, userCode)
      .input('userName', sql.NVarChar, userName)
      .input('latitude', sql.Float, latitude)
      .input('longitude', sql.Float, longitude)
      .input('accuracy', sql.Float, accuracy || 0)
      .input('speed', sql.Float, speed || 0)
      .input('heading', sql.Float, heading || 0)
      .input('timestamp', sql.DateTime2, new Date(timestamp))
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
            timestamp = @timestamp,
            updated_at = GETDATE(),
            isActive = 1
        WHEN NOT MATCHED THEN
          INSERT (userCode, userName, latitude, longitude, accuracy, speed, heading, timestamp, isActive)
          VALUES (@userCode, @userName, @latitude, @longitude, @accuracy, @speed, @heading, @timestamp, 1);
      `);

    console.log(`✅ Location updated for ${userName}: ${latitude}, ${longitude}`);
    rememberLocationUpdate(userCode, parsedLatitude, parsedLongitude);

    broadcastDataChange('location_update', {
      userCode,
      userName,
      latitude,
      longitude,
      accuracy: accuracy || 0,
      timestamp: timestamp || new Date().toISOString(),
      status: 'Active',
    });

    res.json({ success: true, message: 'Location updated successfully' });

  } catch (err) {
    console.error('❌ Error updating location:', err);
    res.status(500).json({ error: 'Failed to update location', details: err.message });
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
