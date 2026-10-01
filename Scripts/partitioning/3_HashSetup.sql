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
    sale_date TIMESTAMP
) PARTITION BY HASH (sales_order_id);

-- Step 2: Create Hash Partitions (5 Sub-Tables)
CREATE TABLE order_details_part_0
PARTITION OF order_details_part
FOR VALUES WITH (MODULUS 5, REMAINDER 0);

CREATE TABLE order_details_part_1
PARTITION OF order_details_part
FOR VALUES WITH (MODULUS 5, REMAINDER 1);

CREATE TABLE order_details_part_2
PARTITION OF order_details_part
FOR VALUES WITH (MODULUS 5, REMAINDER 2);

CREATE TABLE order_details_part_3
PARTITION OF order_details_part
FOR VALUES WITH (MODULUS 5, REMAINDER 3);

CREATE TABLE order_details_part_4
PARTITION OF order_details_part
FOR VALUES WITH (MODULUS 5, REMAINDER 4);

CREATE INDEX idx_order_details_part_0_sales_order_id ON order_details_part_0 (sales_order_id);
CREATE INDEX idx_order_details_part_1_sales_order_id ON order_details_part_1 (sales_order_id);
CREATE INDEX idx_order_details_part_2_sales_order_id ON order_details_part_2 (sales_order_id);
CREATE INDEX idx_order_details_part_3_sales_order_id ON order_details_part_3 (sales_order_id);
CREATE INDEX idx_order_details_part_4_sales_order_id ON order_details_part_4 (sales_order_id);


insert into order_details_part
select 
	salesorderid, salesorderdetailid, carriertrackingnumber, orderqty, productid, 
	specialofferid, unitprice, unitpricediscount, 
	modifieddate
from sales.salesorderdetail;

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

