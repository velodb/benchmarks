copy into time_dim from 's3://${STORAGE_BUCKET}/tpcds/sf1000/time_dim/' FILE_FORMAT =(TYPE = CSV, COMPRESSION = GZIP, FIELD_DELIMITER = '|');
