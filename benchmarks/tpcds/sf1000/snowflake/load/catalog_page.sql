copy into catalog_page from 's3://${STORAGE_BUCKET}/tpcds/sf1000/catalog_page/' FILE_FORMAT =(TYPE = CSV, COMPRESSION = GZIP, FIELD_DELIMITER = '|');
