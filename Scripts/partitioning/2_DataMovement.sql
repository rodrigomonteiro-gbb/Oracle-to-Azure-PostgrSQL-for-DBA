drop table if exists order_details_part;
drop table if exists order_details_staging;
drop table if exists order_details_part_jan_2024;

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
) PARTITION BY RANGE (sale_date);

-- Step 2: Create Monthly Partitions for 2024
CREATE TABLE order_details_part_jan_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE order_details_part_feb_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

CREATE TABLE order_details_part_mar_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');

CREATE TABLE order_details_part_apr_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-04-01') TO ('2024-05-01');

CREATE TABLE order_details_part_may_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-05-01') TO ('2024-06-01');

CREATE TABLE order_details_part_jun_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-06-01') TO ('2024-07-01');

CREATE TABLE order_details_part_jul_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-07-01') TO ('2024-08-01');

CREATE TABLE order_details_part_aug_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-08-01') TO ('2024-09-01');

CREATE TABLE order_details_part_sep_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-09-01') TO ('2024-10-01');

CREATE TABLE order_details_part_oct_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-10-01') TO ('2024-11-01');
/*
CREATE TABLE order_details_part_nov_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-11-01') TO ('2024-12-01');

CREATE TABLE order_details_part_dec_2024
PARTITION OF order_details_part
FOR VALUES FROM ('2024-12-01') TO ('2025-01-01');
*/
-- Step 3: Default Partition (Optional)
CREATE TABLE order_details_part_default
PARTITION OF order_details_part
DEFAULT;

-- Step 4: Add Indexes to Partitions (Optional but Recommended)
CREATE INDEX idx_order_details_part_default_sale_date ON order_details_part_default(sale_date);
CREATE INDEX idx_order_details_part_jan_2024_sale_date ON order_details_part_jan_2024(sale_date);
CREATE INDEX idx_order_details_part_feb_2024_sale_date ON order_details_part_feb_2024(sale_date);
CREATE INDEX idx_order_details_part_mar_2024_sale_date ON order_details_part_mar_2024(sale_date);
CREATE INDEX idx_order_details_part_apr_2024_sale_date ON order_details_part_apr_2024(sale_date);
CREATE INDEX idx_order_details_part_may_2024_sale_date ON order_details_part_may_2024(sale_date);
CREATE INDEX idx_order_details_part_jun_2024_sale_date ON order_details_part_jun_2024(sale_date);
CREATE INDEX idx_order_details_part_jul_2024_sale_date ON order_details_part_jul_2024(sale_date);
CREATE INDEX idx_order_details_part_aug_2024_sale_date ON order_details_part_aug_2024(sale_date);
CREATE INDEX idx_order_details_part_sep_2024_sale_date ON order_details_part_sep_2024(sale_date);
CREATE INDEX idx_order_details_part_oct_2024_sale_date ON order_details_part_oct_2024(sale_date);



insert into order_details_part
select 
	salesorderid, salesorderdetailid, carriertrackingnumber, orderqty, productid, 
	specialofferid, unitprice, unitpricediscount, 
	'01/01/2024'::date + abs(hashint4(salesorderdetailid))% ('2024-10-31'::DATE - '2024-01-01'::DATE)
from sales.salesorderdetail;

--vacuum order_details_part;
SELECT
    c1.relname AS parent_table,
    c2.relname AS child_table, 
	c1.relkind, c1.relpages, c1.reltuples,
	c2.relkind, c2.relpages, c2.reltuples
FROM pg_inherits
JOIN pg_class c1 ON pg_inherits.inhparent = c1.oid
JOIN pg_class c2 ON pg_inherits.inhrelid = c2.oid
WHERE c1.relname = 'order_details_part';


CREATE TABLE order_details_staging_nov2024 (
    sales_order_id INT NOT NULL,
    sales_order_detail_id INT NOT NULL,
    carrier_tracking_number VARCHAR(25),
    order_qty SMALLINT NOT NULL,
    product_id INT NOT NULL,
    special_offer_id INT NOT NULL,
    unit_price NUMERIC(19, 4) NOT NULL,
    unit_price_discount NUMERIC(19, 4) NOT NULL,
    sale_date TIMESTAMP
);

ALTER TABLE order_details_staging_nov2024
ADD CONSTRAINT check_sale_date
CHECK (sale_date >= DATE '2024-11-01' AND sale_date < DATE '2024-12-01');


insert into order_details_staging_nov2024
select 
	salesorderid, salesorderdetailid, carriertrackingnumber, orderqty, productid, 
	specialofferid, unitprice, unitpricediscount, 
	'11/01/2024'::date + abs(hashint4(salesorderdetailid))%30
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



ALTER TABLE order_details_part
ATTACH PARTITION order_details_staging_nov2024
FOR VALUES FROM ('2024-11-01') TO ('2024-12-01');

truncate table order_details_part_jan_2024;

ALTER TABLE order_details_part DETACH PARTITION order_details_part_jan_2024;


explain (analyze)
select *
from order_details_part
where sales_order_detail_id = 2

explain (analyze)
select *
from order_details_part
where sales_order_detail_id = 2 and sale_date = '2024-11-07'


