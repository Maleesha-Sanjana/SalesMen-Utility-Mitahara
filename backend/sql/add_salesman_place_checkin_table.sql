-- Manual salesman place check-ins (one row per location button tap).
-- gen_userLoc keeps the current/live location; this table keeps history for backdate reporting.

IF NOT EXISTS (SELECT * FROM sysobjects WHERE name = 'gen_salesmanPlaceCheckIn' AND xtype = 'U')
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
GO

IF NOT EXISTS (
  SELECT 1
  FROM sys.indexes
  WHERE name = 'IX_gen_salesmanPlaceCheckIn_SalesmanCode_CheckedInAt'
    AND object_id = OBJECT_ID('gen_salesmanPlaceCheckIn')
)
BEGIN
  CREATE INDEX IX_gen_salesmanPlaceCheckIn_SalesmanCode_CheckedInAt
    ON gen_salesmanPlaceCheckIn (SalesmanCode, CheckedInAt DESC);
END
GO
