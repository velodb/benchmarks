copy into catalog_returns from 's3://${STORAGE_BUCKET}/tpcds/sf1000/catalog_returns/' FILE_FORMAT =(TYPE = CSV, COMPRESSION = GZIP, FIELD_DELIMITER = '|');
