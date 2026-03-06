copy into customer_demographics from 's3://${STORAGE_BUCKET}/tpcds/sf1000/customer_demographics/' FILE_FORMAT =(TYPE = CSV, COMPRESSION = GZIP, FIELD_DELIMITER = '|');
