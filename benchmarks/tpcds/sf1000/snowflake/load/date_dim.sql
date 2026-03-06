copy into date_dim from 's3://${STORAGE_BUCKET}/tpcds/sf1000/date_dim/' FILE_FORMAT =(TYPE = CSV, COMPRESSION = GZIP, FIELD_DELIMITER = '|');
