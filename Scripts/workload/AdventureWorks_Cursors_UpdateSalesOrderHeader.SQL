\set salespersonid random(274, 290)

SELECT * FROM demo_salesorderheader_update_cursor(:salespersonid);
