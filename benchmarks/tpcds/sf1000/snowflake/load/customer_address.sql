copy into customer_address from 's3://${STORAGE_BUCKET}/tpcds/sf1000/customer_address/' FILE_FORMAT =(TYPE = CSV, COMPRESSION = GZIP, FIELD_DELIMITER = '|');
