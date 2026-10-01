DROP TABLE IF EXISTS order_details_part;

-- Step 1: Create the Parent Table
CREATE TABLE order_details_part (
    sales_order_id INT NOT NULL,
    sales_order_detail_id INT NOT NULL,
    carrier_tracking_number VARCHAR(25),
    order_qty SMALLINT NOT NULL,
    product_id INT NOT NULL,
    special_offer_id INT NOT NULL,
    unit_price NUMERIC(19, 4) NOT NULL,
    unit_price_discount NUMERIC(19, 4) NOT NULL,
    sale_date TIMESTAMP,
    sales_region TEXT NOT NULL
) PARTITION BY LIST (sales_region);

-- Step 2: Create List Partitions for Each Region
CREATE TABLE order_details_part_east
PARTITION OF order_details_part
FOR VALUES IN ('East');

CREATE TABLE order_details_part_south
PARTITION OF order_details_part
FOR VALUES IN ('South');

CREATE TABLE order_details_part_west
PARTITION OF order_details_part
FOR VALUES IN ('West');

CREATE TABLE order_details_part_north
PARTITION OF order_details_part
FOR VALUES IN ('North');

CREATE TABLE order_details_part_central
PARTITION OF order_details_part
FOR VALUES IN ('Central');

-- Step 3: Default Partition (Optional)
CREATE TABLE order_details_part_default
PARTITION OF order_details_part
DEFAULT;

-- Step 4: Add Indexes to Partitions (Optional but Recommended)
CREATE INDEX idx_order_details_part_east_sales_region ON order_details_part_east (sales_region);
CREATE INDEX idx_order_details_part_south_sales_region ON order_details_part_south (sales_region);
CREATE INDEX idx_order_details_part_west_sales_region ON order_details_part_west (sales_region);
CREATE INDEX idx_order_details_part_north_sales_region ON order_details_part_north (sales_region);
CREATE INDEX idx_order_details_part_central_sales_region ON order_details_part_central (sales_region);


insert into order_details_part
select 
	salesorderid, salesorderdetailid, carriertrackingnumber, orderqty, productid, 
	specialofferid, unitprice, unitpricediscount, modifieddate,
	case salesorderdetailid%5
	when 0 then 'East' when 1 then 'West' when 2 then 'North' when 3 then 'South' else 'Central' end
from sales.salesorderdetail;

SELECT
    c1.relname AS parent_table,
    c2.relname AS child_table, 
	c1.relkind, c1.relpages, c1.reltuples,
	c2.relkind, c2.relpages, c2.reltuples
FROM pg_inherits
JOIN pg_class c1 ON pg_inherits.inhparent = c1.oid
JOIN pg_class c2 ON pg_inherits.inhrelid = c2.oid
WHERE c1.relname = 'order_details_part';

