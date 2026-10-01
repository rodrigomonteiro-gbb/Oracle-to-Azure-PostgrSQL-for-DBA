drop table if exists order_details_part;
-- Step 1: Create the Parent Table
CREATE TABLE order_details_part (
    sales_order_id INT NOT NULL,
    sales_order_detail_id INT NOT NULL, -- SERIAL for auto-increment
    carrier_tracking_number VARCHAR(25), -- NVARCHAR in SQL Server maps to VARCHAR
    order_qty SMALLINT NOT NULL,
    product_id INT NOT NULL,
    special_offer_id INT NOT NULL,
    unit_price NUMERIC(19, 4) NOT NULL, -- MONEY maps to NUMERIC(19, 4)
    unit_price_discount NUMERIC(19, 4) NOT NULL,
    sale_date TIMESTAMP, 
	constraint pk_orderdetails_part primary key (sales_order_detail_id, sale_date)
) PARTITION BY RANGE (sale_date);

-- Step 2: Create Child Tables for Each Range
CREATE TABLE order_details_part_2023
PARTITION OF order_details_part
FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');

CREATE TABLE order_details_part_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

-- Step 3: Default Partition (Optional)
CREATE TABLE order_details_part_default
PARTITION OF order_details_part
DEFAULT;

-- Step 4: Add Indexes to Partitions (Optional but Recommended)
CREATE INDEX idx_order_details_part_default_sale_date ON order_details_part_default(sale_date);
CREATE INDEX idx_order_details_part_2023_sale_date ON order_details_part_2023(sale_date);
CREATE INDEX idx_order_details_part_2024_sale_date ON order_details_part_2024(sale_date);

-- Step 5: Example Insert and Query
insert into order_details_part
select 
	salesorderid, salesorderdetailid, carriertrackingnumber, orderqty, productid, 
	specialofferid, unitprice, unitpricediscount, 
	'01/01/2023'::date + abs(hashint4(salesorderdetailid))% ('2024-11-30'::DATE - '2023-01-01'::DATE)
from sales.salesorderdetail;


SELECT *
FROM pg_partitioned_table pt
JOIN pg_class c ON pt.partrelid = c.oid
WHERE relname = 'order_details';

vacuum order_details_part;
SELECT
    c1.relname AS parent_table,
    c2.relname AS child_table, 
	c1.relkind, c1.relpages, c1.reltuples,
	c2.relkind, c2.relpages, c2.reltuples
FROM pg_inherits
JOIN pg_class c1 ON pg_inherits.inhparent = c1.oid
JOIN pg_class c2 ON pg_inherits.inhrelid = c2.oid
WHERE c1.relname = 'order_details_part';




