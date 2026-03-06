copy into web_sales from 's3://${STORAGE_BUCKET}/tpcds/sf1000/web_sales/' FILE_FORMAT =(TYPE = CSV, COMPRESSION = GZIP, FIELD_DELIMITER = '|');
