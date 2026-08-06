-- Per-user app section rights (salesman + admin portal).
-- One row per salesman/admin code. Missing row = defaults applied by the API.

IF NOT EXISTS (SELECT * FROM sysobjects WHERE name = 'gen_salesmanUseRights' AND xtype = 'U')
BEGIN
  CREATE TABLE gen_salesmanUseRights (
    SalesmanCode NVARCHAR(15) NOT NULL PRIMARY KEY,
    -- Salesman app sections
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
    -- Admin portal sections
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
GO

-- If the table already exists from the earlier script, add admin columns.
IF COL_LENGTH('gen_salesmanUseRights', 'CanAdminSalesmanLocationHistory') IS NULL
BEGIN
  ALTER TABLE gen_salesmanUseRights
    ADD CanAdminSalesmanLocationHistory BIT NOT NULL
      CONSTRAINT DF_gen_salesmanUseRights_CanAdminSalesmanLocationHistory DEFAULT (1);
END
GO

IF COL_LENGTH('gen_salesmanUseRights', 'CanAdminUserCreation') IS NULL
BEGIN
  ALTER TABLE gen_salesmanUseRights
    ADD CanAdminUserCreation BIT NOT NULL
      CONSTRAINT DF_gen_salesmanUseRights_CanAdminUserCreation DEFAULT (1);
END
GO

IF COL_LENGTH('gen_salesmanUseRights', 'CanAdminSalesAndHistory') IS NULL
BEGIN
  ALTER TABLE gen_salesmanUseRights
    ADD CanAdminSalesAndHistory BIT NOT NULL
      CONSTRAINT DF_gen_salesmanUseRights_CanAdminSalesAndHistory DEFAULT (1);
END
GO

IF COL_LENGTH('gen_salesmanUseRights', 'CanAdminLocationTracking') IS NULL
BEGIN
  ALTER TABLE gen_salesmanUseRights
    ADD CanAdminLocationTracking BIT NOT NULL
      CONSTRAINT DF_gen_salesmanUseRights_CanAdminLocationTracking DEFAULT (1);
END
GO

IF COL_LENGTH('gen_salesmanUseRights', 'CanAdminCurrentSale') IS NULL
BEGIN
  ALTER TABLE gen_salesmanUseRights
    ADD CanAdminCurrentSale BIT NOT NULL
      CONSTRAINT DF_gen_salesmanUseRights_CanAdminCurrentSale DEFAULT (1);
END
GO
