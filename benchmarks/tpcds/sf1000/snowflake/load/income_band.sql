copy into income_band from 's3://${STORAGE_BUCKET}/tpcds/sf1000/income_band/' FILE_FORMAT =(TYPE = CSV, COMPRESSION = GZIP, FIELD_DELIMITER = '|');
