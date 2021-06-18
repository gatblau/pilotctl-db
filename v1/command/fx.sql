/*
    Onix Pilot Control Service - Copyright (c) 2018-2021 by www.gatblau.org

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
    Unless required by applicable law or agreed to in writing, software distributed under
    the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
    either express or implied.
    See the License for the specific language governing permissions and limitations under the License.

    Contributors to this project, hereby assign copyright in this code to the project,
    to be licensed under the same terms as the rest of the code.
*/
DO
$$
    BEGIN
        -- inserts or updates the last_seen timestamp for a host
        CREATE OR REPLACE FUNCTION pilotctl_beat(
            host_key_param CHARACTER VARYING(100)
        )
            RETURNS VOID
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        DECLARE
            host_count SMALLINT;
        BEGIN
            -- checks if the entry exists
            SELECT COUNT(*) FROM host WHERE key = host_key_param INTO host_count;

            -- if the host does not exist, insert a new entry
            IF host_count = 0 THEN
                INSERT INTO host(key, last_seen) VALUES (host_key_param, now());
            ELSE -- otherwise, update the last_seen timestamp
                UPDATE host SET last_seen = now() WHERE key = host_key_param;
            END IF;
        END;
        $BODY$;

        -- record server side connected/disconnected events using information in host table
        CREATE OR REPLACE FUNCTION pilotctl_record_conn_status(
            after INTERVAL
        )
            RETURNS VOID
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            -- insert any new hosts in the status table
            INSERT INTO STATUS
            SELECT h.id,
                   CASE WHEN h.last_seen < now() - after THEN false ELSE true END,
                   h.last_seen
            FROM host h
                     LEFT JOIN status s
                               ON s.host_id = h.id
            WHERE s.host_id IS NULL;

            -- update existing hosts in the status table
            UPDATE status
            SET host_id=h.id,
                connected=CASE WHEN h.last_seen < now() - after THEN false ELSE true END,
                since=h.last_seen
            FROM host h
                     LEFT JOIN status s
                               ON s.host_id = h.id
            WHERE s.host_id IS NOT NULL
              AND s.connected <> CASE WHEN h.last_seen < now() - after THEN false ELSE true END;
        END ;
        $BODY$;

        -- return connection status
        CREATE OR REPLACE FUNCTION pilotctl_get_conn_status(
        )
            RETURNS TABLE
                    (
                        host      CHARACTER VARYING,
                        connected BOOLEAN,
                        since     TIMESTAMP(6) WITH TIME ZONE,
                        customer  CHARACTER VARYING,
                        region    CHARACTER VARYING,
                        location  CHARACTER VARYING
                    )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            RETURN QUERY
                SELECT h.key as host, s.connected, s.since, h.customer, h.region, h.location
                FROM status s
                         INNER JOIN host h
                                    ON h.id = s.host_id;
        END ;
        $BODY$;

        -- insert or update admission
        CREATE OR REPLACE FUNCTION pilotctl_set_admission(
            host_key_param VARCHAR(100),
            active_param BOOLEAN,
            tag_param TEXT[]
        )
            RETURNS VOID
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            INSERT INTO admission (host_key, active, tag)
            VALUES (host_key_param, active_param, tag_param)
            ON CONFLICT (host_key)
                DO UPDATE
                SET active = active_param,
                    tag    = tag_param;
        END ;
        $BODY$;

        -- get admission status
        CREATE OR REPLACE FUNCTION pilotctl_is_admitted(
            host_key_param VARCHAR(100)
        )
            RETURNS BOOLEAN
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        DECLARE
            admitted BOOLEAN;
        BEGIN
            SELECT EXISTS INTO admitted (
            SELECT 1
            FROM admission
            WHERE host_key = host_key_param
              AND active = TRUE );
            RETURN admitted;
        END ;
        $BODY$;

        -- get admissions by tag or all admissions if tag is null
        CREATE OR REPLACE FUNCTION pilotctl_get_admissions(
            tag_param TEXT[]
        )
            RETURNS TABLE
                    (
                        host_key CHARACTER VARYING,
                        active   BOOLEAN,
                        tag      TEXT[]
                    )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        DECLARE
            admitted BOOLEAN;
        BEGIN
            RETURN QUERY
                SELECT a.host_key,
                       a.active,
                       a.tag
                FROM admission a
                WHERE (a.tag @> tag_param OR tag_param IS NULL);
        END ;
        $BODY$;

        -- insert or update a command definition
        CREATE OR REPLACE FUNCTION pilotctl_set_command(
            name_param VARCHAR(100),
            description_param TEXT,
            package_param VARCHAR(100),
            fx_param VARCHAR(100),
            input_param JSONB
        )
            RETURNS VOID
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            INSERT INTO command (name, description, package, fx, input)
            VALUES (name_param, description_param, package_param, fx_param, input_param)
            ON CONFLICT (name)
                DO UPDATE
                SET description = description_param,
                    package     = package_param,
                    fx          = fx_param,
                    input       = input_param;
        END ;
        $BODY$;

        -- return connection status
        CREATE OR REPLACE FUNCTION pilotctl_get_command(
            name_param VARCHAR(100)
        )
            RETURNS TABLE
                    (
                        id          BIGINT,
                        name        CHARACTER VARYING(100),
                        description TEXT,
                        package     CHARACTER VARYING(100),
                        fx          CHARACTER VARYING(100),
                        input       JSONB,
                        created     TIMESTAMP(6) WITH TIME ZONE,
                        updated     TIMESTAMP(6) WITH TIME ZONE
                    )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            RETURN QUERY
                SELECT c.id,
                       c.name,
                       c.description,
                       c.package,
                       c.fx,
                       c.input,
                       c.created,
                       c.updated
                FROM command c
                WHERE (c.name = name_param OR name_param IS NULL);
        END ;
        $BODY$;

        -- create a new job for executing a command on a host
        CREATE OR REPLACE FUNCTION pilotctl_create_job(
            host_key_param VARCHAR(100),
            command_name_param VARCHAR(100)
        )
            RETURNS VOID
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        DECLARE
            host_id_var    BIGINT;
            command_id_var BIGINT;
        BEGIN
            -- capture the host surrogate key
            SELECT h.id FROM host h WHERE h.key = host_key_param INTO host_id_var;
            -- capture the command surrogate key
            SELECT c.id FROM command c WHERE c.name = command_name_param INTO command_id_var;
            -- insert a job entry
            INSERT INTO job (host_id, command_id, created) VALUES (host_id_var, command_id_var, now());
        END ;
        $BODY$;

        -- get number of jobs scheduled but not yet started for a host
        CREATE OR REPLACE FUNCTION pilotctl_scheduled_jobs(
            host_key_param VARCHAR(100)
        )
            RETURNS INT
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        DECLARE
            count INT;
        BEGIN
            count := (
                SELECT COUNT(*) as jobs_in_progress
                FROM job j
                         INNER JOIN host h ON h.id = j.host_id
                WHERE h.key = host_key_param
                  AND j.scheduled IS NOT NULL
                  AND j.started IS NULL
            );
            RETURN count;
        END;
        $BODY$;

        -- gets the next job for a host
        -- if no job is available then returned job_id is -1
        -- if a job is found, its status is changed from "created" to "scheduled"
        CREATE OR REPLACE FUNCTION pilotctl_get_next_job(
            host_key_param VARCHAR(100)
        )
            RETURNS TABLE
                    (
                        job_id  BIGINT,
                        package CHARACTER VARYING(100),
                        fx      CHARACTER VARYING(100),
                        input   JSONB
                    )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        DECLARE
            job_id_var  BIGINT;
            package_var CHARACTER VARYING(100);
            fx_var      CHARACTER VARYING(100);
            input_var   JSONB;
        BEGIN
            -- identify oldest job that needs scheduling only if no other jobs have been already scheduled
            -- and are waiting to start
            SELECT j.id, c.package, c.fx, c.input
            INTO job_id_var, package_var, fx_var, input_var
            FROM job j
                     INNER JOIN host h ON h.id = j.host_id
                     INNER JOIN command c ON c.id = j.command_id
            WHERE h.key = host_key_param
              -- job has not been picked by the service yet
              AND j.scheduled IS NULL
              -- there are no other jobs scheduled and waiting to start for the host_key_param
              AND pilotctl_scheduled_jobs(host_key_param) = 0
              -- older job first
            ORDER BY j.created ASC
                     -- only interested in one job at a time
            LIMIT 1;

            IF FOUND THEN
                -- change the job status to scheduled
                UPDATE job SET scheduled = NOW() WHERE id = job_id_var;
            ELSE
                -- ensure the return value is less than zero to indicate a job has not been found
                job_id_var = -1;
            END IF;
            -- return the result
            RETURN QUERY
                SELECT job_id_var, package_var, fx_var, input_var;
        END;
        $BODY$;
    END;
$$