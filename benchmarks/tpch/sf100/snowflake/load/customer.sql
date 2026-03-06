copy into customer
from
    's3://${STORAGE_BUCKET}/tpch/sf100/customer/' FILE_FORMAT = (
        TYPE = CSV,
        FIELD_DELIMITER = '|',
        ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    );