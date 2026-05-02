make build-polaris-images
make polaris-down
make adw-reset 
make polaris-up 
./src/create_polaris_s3_catalog.sh
python src/generate_iceberg_tables.py 
