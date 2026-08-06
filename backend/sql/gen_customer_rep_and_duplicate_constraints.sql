/*
  gen_customer: sales-rep scoping + NIC/mobile duplicate prevention

  Run on: ERP_SOLUTIONtst (or your ERP database)

  Notes:
  - SalesRepCode already exists on gen_customer. No new rep column is required.
  - CustomerId stores NIC from the mobile app.
  - Clean up duplicate NIC/mobile rows BEFORE creating unique indexes.
*/

USE [ERP_SOLUTIONtst];
GO

/* Optional but recommended: allow full NIC values (old/new formats). */
IF COL_LENGTH('dbo.gen_customer', 'CustomerId') < 15
BEGIN
    ALTER TABLE dbo.gen_customer
    ALTER COLUMN CustomerId NVARCHAR(15) NULL;
END
GO

/*
  Preview duplicate NIC values (same NIC on multiple customers).
  Resolve these manually before creating the unique index.
*/
SELECT
    UPPER(LTRIM(RTRIM(CustomerId))) AS nic,
    COUNT(*) AS duplicateCount
FROM dbo.gen_customer
WHERE CustomerId IS NOT NULL
  AND LTRIM(RTRIM(CustomerId)) <> ''
GROUP BY UPPER(LTRIM(RTRIM(CustomerId)))
HAVING COUNT(*) > 1;
GO

/*
  Preview duplicate mobile values (spaces/dashes ignored).
  Resolve these manually before creating the unique index.
*/
SELECT
    REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(Mobile)), ' ', ''), '-', ''), '+', '') AS mobileNormalized,
    COUNT(*) AS duplicateCount
FROM dbo.gen_customer
WHERE Mobile IS NOT NULL
  AND LTRIM(RTRIM(Mobile)) <> ''
GROUP BY REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(Mobile)), ' ', ''), '-', ''), '+', '')
HAVING COUNT(*) > 1;
GO

/* Unique NIC when provided. */
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'UX_gen_customer_CustomerId'
      AND object_id = OBJECT_ID('dbo.gen_customer')
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UX_gen_customer_CustomerId
    ON dbo.gen_customer (CustomerId)
    WHERE CustomerId IS NOT NULL
      AND LTRIM(RTRIM(CustomerId)) <> '';
END
GO

/*
  Unique mobile when provided.
  Uses raw Mobile column; the API normalizes spaces/dashes before save/check.
*/
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'UX_gen_customer_Mobile'
      AND object_id = OBJECT_ID('dbo.gen_customer')
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UX_gen_customer_Mobile
    ON dbo.gen_customer (Mobile)
    WHERE Mobile IS NOT NULL
      AND LTRIM(RTRIM(Mobile)) <> '';
END
GO

/* Optional: speed up rep-scoped customer lists used by the mobile app. */
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_gen_customer_SalesRepCode'
      AND object_id = OBJECT_ID('dbo.gen_customer')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_gen_customer_SalesRepCode
    ON dbo.gen_customer (SalesRepCode, CustomerName, CustomerCode)
    INCLUDE (Mobile, CustomerId, Address1, Address3, Suspend, BlackListed);
END
GO
