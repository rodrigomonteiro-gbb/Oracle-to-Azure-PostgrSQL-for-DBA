# pg_stat_statements
</br>

## Use
</br>
pg_stat_statements is to postgreSQL what Query Store is for SQL Server. It stores aggregated execution of queries in the memory

## Capturing pg_stat_statements Before/After

</br>
to reset its contents from previous executions we need to reset it, by executing the following sql command:
</br>
</br>
`powershell

psql -h $Server -U $User -d $Database `
-c "SELECT **pg_stat_statements_reset()**;"`

</br>
</br>