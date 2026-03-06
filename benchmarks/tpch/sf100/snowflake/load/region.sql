copy into region
from
    's3://${STORAGE_BUCKET}/tpch/sf100/region/' FILE_FORMAT = (
        TYPE = CSV,
        FIELD_DELIMITER = '|',
        ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    );