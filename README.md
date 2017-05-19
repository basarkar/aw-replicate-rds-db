# AWS RDS COPY FROM PROD to STAGE FROM PROD RDS IMAGE

Creates a new RDS instance by cloning the latest production snapshot.
More specifically, the following steps are performed:
   - Determine the snapshot id to use
   - Delete the existing database
   - Create the new database
   - Make necessary modifications to the new instances (disable backups)