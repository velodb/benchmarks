copy into store_sales from 's3://${STORAGE_BUCKET}/tpcds/sf1000/store_sales/' FILE_FORMAT =(TYPE = CSV, COMPRESSION = GZIP, FIELD_DELIMITER = '|');
