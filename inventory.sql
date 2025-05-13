-- Create Database
IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = 'InventoryDB')
BEGIN
    CREATE DATABASE InventoryDB;
END
GO

USE InventoryDB;
GO

-- Create Categories Table
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Categories')
BEGIN
    CREATE TABLE Categories (
        CategoryID INT IDENTITY(1,1) PRIMARY KEY,
        CategoryName NVARCHAR(100) NOT NULL,
        Description NVARCHAR(500),
        CreatedDate DATETIME DEFAULT GETDATE(),
        ModifiedDate DATETIME DEFAULT GETDATE()
    );
END
GO

-- Create Suppliers Table
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Suppliers')
BEGIN
    CREATE TABLE Suppliers (
        SupplierID INT IDENTITY(1,1) PRIMARY KEY,
        SupplierName NVARCHAR(200) NOT NULL,
        ContactPerson NVARCHAR(100),
        Email NVARCHAR(100),
        Phone NVARCHAR(20),
        Address NVARCHAR(500),
        CreatedDate DATETIME DEFAULT GETDATE(),
        ModifiedDate DATETIME DEFAULT GETDATE()
    );
END
GO

-- Create Products Table
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Products')
BEGIN
    CREATE TABLE Products (
        ProductID INT IDENTITY(1,1) PRIMARY KEY,
        ProductName NVARCHAR(200) NOT NULL,
        CategoryID INT FOREIGN KEY REFERENCES Categories(CategoryID),
        SupplierID INT FOREIGN KEY REFERENCES Suppliers(SupplierID),
        SKU NVARCHAR(50) UNIQUE,
        Description NVARCHAR(500),
        UnitPrice DECIMAL(18,2) NOT NULL,
        ReorderLevel INT DEFAULT 10,
        CurrentStock INT DEFAULT 0,
        CreatedDate DATETIME DEFAULT GETDATE(),
        ModifiedDate DATETIME DEFAULT GETDATE()
    );
END
GO

-- Create StockMovements Table
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'StockMovements')
BEGIN
    CREATE TABLE StockMovements (
        MovementID INT IDENTITY(1,1) PRIMARY KEY,
        ProductID INT FOREIGN KEY REFERENCES Products(ProductID),
        MovementType NVARCHAR(20) CHECK (MovementType IN ('IN', 'OUT')),
        Quantity INT NOT NULL,
        UnitPrice DECIMAL(18,2) NOT NULL,
        TotalAmount DECIMAL(18,2),
        Reference NVARCHAR(100),
        Notes NVARCHAR(500),
        MovementDate DATETIME DEFAULT GETDATE()
    );
END
GO

-- Create trigger to update CurrentStock in Products table
IF EXISTS (SELECT * FROM sys.triggers WHERE name = 'TR_StockMovements_UpdateStock')
    DROP TRIGGER TR_StockMovements_UpdateStock;
GO

CREATE TRIGGER TR_StockMovements_UpdateStock
ON StockMovements
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    -- Update Products.CurrentStock based on movement type
    UPDATE p
    SET p.CurrentStock = p.CurrentStock + 
        CASE 
            WHEN i.MovementType = 'IN' THEN i.Quantity
            WHEN i.MovementType = 'OUT' THEN -i.Quantity
        END,
        p.ModifiedDate = GETDATE()
    FROM Products p
    INNER JOIN inserted i ON p.ProductID = i.ProductID;
END
GO

-- Create trigger to update ModifiedDate in Products table
IF EXISTS (SELECT * FROM sys.triggers WHERE name = 'TR_Products_UpdateModifiedDate')
    DROP TRIGGER TR_Products_UpdateModifiedDate;
GO

CREATE TRIGGER TR_Products_UpdateModifiedDate
ON Products
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    
    UPDATE Products
    SET ModifiedDate = GETDATE()
    FROM Products p
    INNER JOIN inserted i ON p.ProductID = i.ProductID;
END
GO

-- Insert sample data
-- Categories
INSERT INTO Categories (CategoryName, Description)
VALUES 
    ('Electronics', 'Electronic devices and accessories'),
    ('Office Supplies', 'General office supplies and stationery'),
    ('Furniture', 'Office furniture and fixtures');

-- Suppliers
INSERT INTO Suppliers (SupplierName, ContactPerson, Email, Phone, Address)
VALUES
    ('Tech Supplies Inc.', 'John Doe', 'john@techsupplies.com', '555-0100', '123 Tech Street'),
    ('Office Plus', 'Jane Smith', 'jane@officeplus.com', '555-0200', '456 Office Avenue'),
    ('Furniture World', 'Mike Johnson', 'mike@furnitureworld.com', '555-0300', '789 Furniture Road');

-- Products
INSERT INTO Products (ProductName, CategoryID, SupplierID, SKU, Description, UnitPrice, ReorderLevel, CurrentStock)
VALUES
    ('Laptop', 1, 1, 'LAP001', 'Business laptop', 999.99, 5, 10),
    ('Printer Paper', 2, 2, 'PAP001', 'A4 printer paper, 500 sheets', 5.99, 20, 100),
    ('Office Chair', 3, 3, 'CHR001', 'Ergonomic office chair', 199.99, 3, 8);

-- Create Views for common queries
-- View for low stock products
CREATE OR ALTER VIEW vw_LowStockProducts
AS
SELECT 
    p.ProductID,
    p.ProductName,
    p.CurrentStock,
    p.ReorderLevel,
    c.CategoryName,
    s.SupplierName,
    s.ContactPerson,
    s.Phone
FROM Products p
INNER JOIN Categories c ON p.CategoryID = c.CategoryID
INNER JOIN Suppliers s ON p.SupplierID = s.SupplierID
WHERE p.CurrentStock <= p.ReorderLevel;
GO

-- View for stock movement history
CREATE OR ALTER VIEW vw_StockMovementHistory
AS
SELECT 
    sm.MovementID,
    p.ProductName,
    sm.MovementType,
    sm.Quantity,
    sm.UnitPrice,
    sm.TotalAmount,
    sm.Reference,
    sm.MovementDate,
    c.CategoryName
FROM StockMovements sm
INNER JOIN Products p ON sm.ProductID = p.ProductID
INNER JOIN Categories c ON p.CategoryID = c.CategoryID;
GO

-- Stored Procedure for adding stock
CREATE OR ALTER PROCEDURE sp_AddStock
    @ProductID INT,
    @Quantity INT,
    @UnitPrice DECIMAL(18,2),
    @Reference NVARCHAR(100) = NULL,
    @Notes NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    
    INSERT INTO StockMovements (
        ProductID,
        MovementType,
        Quantity,
        UnitPrice,
        TotalAmount,
        Reference,
        Notes
    )
    VALUES (
        @ProductID,
        'IN',
        @Quantity,
        @UnitPrice,
        @Quantity * @UnitPrice,
        @Reference,
        @Notes
    );
END
GO

-- Stored Procedure for removing stock
CREATE OR ALTER PROCEDURE sp_RemoveStock
    @ProductID INT,
    @Quantity INT,
    @UnitPrice DECIMAL(18,2),
    @Reference NVARCHAR(100) = NULL,
    @Notes NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Check if we have enough stock
    IF EXISTS (SELECT 1 FROM Products WHERE ProductID = @ProductID AND CurrentStock >= @Quantity)
    BEGIN
        INSERT INTO StockMovements (
            ProductID,
            MovementType,
            Quantity,
            UnitPrice,
            TotalAmount,
            Reference,
            Notes
        )
        VALUES (
            @ProductID,
            'OUT',
            @Quantity,
            @UnitPrice,
            @Quantity * @UnitPrice,
            @Reference,
            @Notes
        );
    END
    ELSE
        THROW 50001, 'Insufficient stock available', 1;
END
GO 