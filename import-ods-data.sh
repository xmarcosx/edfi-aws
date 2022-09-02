export PGPASSWORD=$1;
psql -h $2 -U postgres  'EdFi_Admin' < artifacts/edfi-ods-admin/EdFi_Admin.sql;
psql -h $2 -U postgres  'EdFi_Security' < artifacts/edfi-ods-security/EdFi_Security.sql;
psql -h $2 -U postgres  'EdFi_Ods_2023' < artifacts/edfi-ods-minimal/EdFi.Ods.Minimal.Template.TPDM.Core.sql;
psql -h $2 -U postgres  'EdFi_Ods_2022' < artifacts/edfi-ods-minimal/EdFi.Ods.Minimal.Template.TPDM.Core.sql;
psql -h $2 -U postgres  'EdFi_Ods_2021' < artifacts/edfi-ods-minimal/EdFi.Ods.Minimal.Template.TPDM.Core.sql;

for FILE in `LANG=C ls artifacts/ed-fi-ods-admin-scripts/PgSql/* | sort -V`
    do
        psql -h $2 -U postgres 'EdFi_Admin' < $FILE 
    done