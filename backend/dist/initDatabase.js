async function initializeDatabase(pool) {
    console.log('Initializing database schema...');
    try {
        const migrationQuery = `
-- 1. Add isAdmin, isSuper, password, isLogged, salesmanImg columns to gen_salesman
IF COL_LENGTH('gen_salesman', 'isAdmin') IS NULL
    ALTER TABLE gen_salesman ADD isAdmin BIT NOT NULL DEFAULT 0;
    
IF COL_LENGTH('gen_salesman', 'isSuper') IS NULL
    ALTER TABLE gen_salesman ADD isSuper BIT NOT NULL DEFAULT 0;
    
IF COL_LENGTH('gen_salesman', 'password') IS NULL
    ALTER TABLE gen_salesman ADD password NVARCHAR(255) NULL;
    
IF COL_LENGTH('gen_salesman', 'isLogged') IS NULL
    ALTER TABLE gen_salesman ADD isLogged BIT NOT NULL DEFAULT 0;
    
IF COL_LENGTH('gen_salesman', 'salesmanImg') IS NULL
    ALTER TABLE gen_salesman ADD salesmanImg VARBINARY(MAX) NULL;

-- 2. Create gen_userLoc table
IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='gen_userLoc' and xtype='U')
BEGIN
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
    );
END

-- 3. Add Latitude, Longitude, CreatedSalesman, Assigned to gen_customer
IF COL_LENGTH('gen_customer', 'Latitude') IS NULL
    ALTER TABLE dbo.gen_customer ADD Latitude DECIMAL(10, 8) NULL;
    
IF COL_LENGTH('gen_customer', 'Longitude') IS NULL
    ALTER TABLE dbo.gen_customer ADD Longitude DECIMAL(11, 8) NULL;
    
IF COL_LENGTH('gen_customer', 'CreatedSalesman') IS NULL
    ALTER TABLE dbo.gen_customer ADD CreatedSalesman NVARCHAR(15) NULL;
    
IF COL_LENGTH('gen_customer', 'Assigned') IS NULL
    ALTER TABLE dbo.gen_customer ADD Assigned BIT NOT NULL DEFAULT 0;

-- Alter CustomerId in gen_customer
IF COL_LENGTH('gen_customer', 'CustomerId') IS NOT NULL
    ALTER TABLE dbo.gen_customer ALTER COLUMN CustomerId NVARCHAR(15) NULL;

-- 4. Create gen_userDevice table and related objects
IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='gen_userDevice' and xtype='U')
BEGIN
    CREATE TABLE gen_userDevice (
        id INT IDENTITY(1,1) PRIMARY KEY,
        deviceId NVARCHAR(100) NOT NULL,
        userCode NVARCHAR(50) NOT NULL,
        userName NVARCHAR(100) NOT NULL,
        deviceName NVARCHAR(100) NULL,
        deviceModel NVARCHAR(100) NULL,
        platform NVARCHAR(20) NULL,        -- android, ios, web
        osVersion NVARCHAR(50) NULL,
        appVersion NVARCHAR(20) NULL,
        isAdmin BIT NOT NULL DEFAULT 0,
        isSuper BIT NOT NULL DEFAULT 0,
        firstSeenAt DATETIME2 NOT NULL DEFAULT GETDATE(),
        lastSeenAt DATETIME2 NOT NULL DEFAULT GETDATE(),
        isActive BIT NOT NULL DEFAULT 1,
        isAllowed BIT NOT NULL CONSTRAINT DF_gen_userDevice_isAllowed DEFAULT 1,
        approvedAt DATETIME2 NULL,
        approvedBy NVARCHAR(100) NULL,
        CONSTRAINT UQ_gen_userDevice_deviceId UNIQUE (deviceId)
    );
    
    CREATE INDEX IX_gen_userDevice_lastSeenAt ON gen_userDevice (lastSeenAt DESC, isActive);
END
ELSE
BEGIN
    IF COL_LENGTH('gen_userDevice', 'isAllowed') IS NULL
        ALTER TABLE gen_userDevice ADD isAllowed BIT NOT NULL CONSTRAINT DF_gen_userDevice_isAllowed DEFAULT 1;
        
    IF COL_LENGTH('gen_userDevice', 'approvedAt') IS NULL
        ALTER TABLE gen_userDevice ADD approvedAt DATETIME2 NULL;
        
    IF COL_LENGTH('gen_userDevice', 'approvedBy') IS NULL
        ALTER TABLE gen_userDevice ADD approvedBy NVARCHAR(100) NULL;
END

-- 5. Create gen_salesmanPlaceCheckIn
IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='gen_salesmanPlaceCheckIn' and xtype='U')
BEGIN
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
END

-- 6. Create gen_salesmanUseRights
IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='gen_salesmanUseRights' and xtype='U')
BEGIN
    CREATE TABLE gen_salesmanUseRights (
        SalesmanCode NVARCHAR(15) NOT NULL PRIMARY KEY,
        CanSalesOrder BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanSalesOrder DEFAULT (1),
        CanInvoice BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanInvoice DEFAULT (1),
        CanQuotation BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanQuotation DEFAULT (1),
        CanCRN BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanCRN DEFAULT (1),
        CanMySalesHistory BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanMySalesHistory DEFAULT (1),
        CanCustomerCreate BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanCustomerCreate DEFAULT (1),
        CanCustomerLocations BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanCustomerLocations DEFAULT (1),
        CanLeaderboard BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanLeaderboard DEFAULT (1),
        CanStockReports BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanStockReports DEFAULT (0),
        CanReceipts BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanReceipts DEFAULT (0),
        CanAdminSalesmanLocationHistory BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanAdminSalesmanLocationHistory DEFAULT (1),
        CanAdminUserCreation BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanAdminUserCreation DEFAULT (1),
        CanAdminSalesAndHistory BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanAdminSalesAndHistory DEFAULT (1),
        CanAdminLocationTracking BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanAdminLocationTracking DEFAULT (1),
        CanAdminCurrentSale BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanAdminCurrentSale DEFAULT (1),
        Created_User NVARCHAR(50) NULL,
        Created_Date DATETIME2 NOT NULL CONSTRAINT DF_gen_salesmanUseRights_Created_Date DEFAULT (GETDATE()),
        Edited_User NVARCHAR(50) NULL,
        Edited_Date DATETIME2 NULL
    );
END
ELSE
BEGIN
    IF COL_LENGTH('gen_salesmanUseRights', 'CanAdminSalesmanLocationHistory') IS NULL
        ALTER TABLE gen_salesmanUseRights ADD CanAdminSalesmanLocationHistory BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanAdminSalesmanLocationHistory DEFAULT (1);
        
    IF COL_LENGTH('gen_salesmanUseRights', 'CanAdminUserCreation') IS NULL
        ALTER TABLE gen_salesmanUseRights ADD CanAdminUserCreation BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanAdminUserCreation DEFAULT (1);
        
    IF COL_LENGTH('gen_salesmanUseRights', 'CanAdminSalesAndHistory') IS NULL
        ALTER TABLE gen_salesmanUseRights ADD CanAdminSalesAndHistory BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanAdminSalesAndHistory DEFAULT (1);
        
    IF COL_LENGTH('gen_salesmanUseRights', 'CanAdminLocationTracking') IS NULL
        ALTER TABLE gen_salesmanUseRights ADD CanAdminLocationTracking BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanAdminLocationTracking DEFAULT (1);
        
    IF COL_LENGTH('gen_salesmanUseRights', 'CanAdminCurrentSale') IS NULL
        ALTER TABLE gen_salesmanUseRights ADD CanAdminCurrentSale BIT NOT NULL CONSTRAINT DF_gen_salesmanUseRights_CanAdminCurrentSale DEFAULT (1);
END
        `;

        await pool.request().query(migrationQuery);
        console.log('Database schema initialization completed successfully.');
    } catch (err) {
        console.error('Error initializing database schema:', err);
    }
}

module.exports = initializeDatabase;
