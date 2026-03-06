copy into ship_mode from 's3://${STORAGE_BUCKET}/tpcds/sf1000/ship_mode/' FILE_FORMAT =(TYPE = CSV, COMPRESSION = GZIP, FIELD_DELIMITER = '|');
