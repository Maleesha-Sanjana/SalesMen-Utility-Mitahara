/*
  Add CreatedSalesman to gen_customer

  Purpose:
  - Stores which salesman registered the customer from the mobile app.
  - Used to show each rep only their own customers in SO / Invoice / Quotation / CRN.

  Run on: ERP_SOLUTIONtst (or your ERP database)
*/

USE [ERP_SOLUTIONtst];
GO

IF COL_LENGTH('dbo.gen_customer', 'CreatedSalesman') IS NULL
BEGIN
    ALTER TABLE dbo.gen_customer
    ADD CreatedSalesman NVARCHAR(15) NULL;
END
GO

/*
  Optional backfill — only run if you want old ERP customers tied to SalesRepCode.
  Leave CreatedSalesman empty to keep them visible to all reps until one rep updates them.

UPDATE dbo.gen_customer
SET CreatedSalesman = LTRIM(RTRIM(SalesRepCode))
WHERE (CreatedSalesman IS NULL OR LTRIM(RTRIM(CreatedSalesman)) = '')
  AND SalesRepCode IS NOT NULL
  AND LTRIM(RTRIM(SalesRepCode)) <> '';
GO
*/

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_gen_customer_CreatedSalesman'
      AND object_id = OBJECT_ID('dbo.gen_customer')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_gen_customer_CreatedSalesman
    ON dbo.gen_customer (CreatedSalesman, CustomerName, CustomerCode)
    INCLUDE (Mobile, CustomerId, Address1, Address3, Suspend, BlackListed);
END
GO
