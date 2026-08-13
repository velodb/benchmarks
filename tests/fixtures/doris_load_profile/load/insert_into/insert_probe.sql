INSERT INTO insert_probe
SELECT number, CAST(number AS STRING)
FROM numbers("number"="100000");
