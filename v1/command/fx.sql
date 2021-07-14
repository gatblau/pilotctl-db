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
            machine_id_param CHARACTER VARYING(100)
        )
            RETURNS TABLE
            (
                job_id     BIGINT,
                fx_key     CHARACTER VARYING(100),
                fx_version BIGINT
            )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        DECLARE
            host_count SMALLINT;
        BEGIN
            -- checks if the entry exists
            SELECT COUNT(*) FROM host WHERE machine_id = machine_id_param INTO host_count;
            -- if the host does not exist, insert a new entry
            IF host_count = 0 THEN
                INSERT INTO host(machine_id, last_seen, in_service) VALUES (machine_id_param, now(), true);
            ELSE -- otherwise, update the last_seen timestamp
                UPDATE host
                SET last_seen = now(),
                    -- any beat revert in_service flag to true
                    in_service = true
                WHERE machine_id = machine_id_param;
            END IF;
            -- finally get the next job for the machine id (if any exists, if not job_id < 0)
            RETURN QUERY
                SELECT j.job_id, j.fx_key, j.fx_version
                FROM pilotctl_get_next_job(machine_id_param) j;
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
            LEFT JOIN status s ON s.host_id = h.id
            WHERE s.host_id IS NULL;

            -- update existing hosts in the status table
            UPDATE status
            SET host_id=h.id,
                connected=CASE WHEN h.last_seen < now() - after THEN false ELSE true END,
                since=h.last_seen
            FROM host h
            LEFT JOIN status s ON s.host_id = h.id
            WHERE s.host_id IS NOT NULL
              AND s.connected <> CASE WHEN h.last_seen < now() - after THEN false ELSE true END;
        END ;
        $BODY$;

        -- return connection status
        CREATE OR REPLACE FUNCTION pilotctl_get_conn_status(
        )
            RETURNS TABLE
            (
                host       CHARACTER VARYING,
                connected  BOOLEAN,
                since      TIMESTAMP(6) WITH TIME ZONE,
                customer   CHARACTER VARYING,
                region     CHARACTER VARYING,
                location   CHARACTER VARYING,
                in_service BOOLEAN
            )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            RETURN QUERY
                SELECT h.machine_id,
                       s.connected,
                       s.since,
                       h.customer,
                       h.region,
                       h.location,
                       h.in_service
                FROM status s
                INNER JOIN host h
                  ON h.id = s.host_id;
        END ;
        $BODY$;

        -- ADMISSIONS

        -- insert or update admission
        CREATE OR REPLACE FUNCTION pilotctl_set_admission(
            machine_id_param VARCHAR(100),
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
            INSERT INTO admission (machine_id, active, tag)
            VALUES (machine_id_param, active_param, tag_param)
            ON CONFLICT (machine_id)
                DO UPDATE
                SET active = active_param,
                    tag    = tag_param;
        END ;
        $BODY$;

        -- get admission status
        CREATE OR REPLACE FUNCTION pilotctl_is_admitted(
            machine_id_param VARCHAR(100)
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
                -- there is an entry for the machine id and is set to active
                WHERE machine_id = machine_id_param AND active = TRUE
            );
            RETURN admitted;
        END ;
        $BODY$;

        -- get admissions by tag or all admissions if tag is null
        CREATE OR REPLACE FUNCTION pilotctl_get_admissions(
            tag_param TEXT[]
        )
            RETURNS TABLE
            (
                machine_id CHARACTER VARYING,
                active   BOOLEAN,
                tag      TEXT[]
            )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            RETURN QUERY
                SELECT a.machine_id,
                       a.active,
                       a.tag
                FROM admission a
                WHERE (a.tag @> tag_param OR tag_param IS NULL);
        END ;
        $BODY$;

        -- JOBS

        -- create a new job for executing a command on a host
        CREATE OR REPLACE FUNCTION pilotctl_create_job(
            machine_id_param VARCHAR(100),
            fx_key_param VARCHAR(100)
        )
            RETURNS VOID
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        DECLARE
            host_id_var    BIGINT;
        BEGIN
            -- capture the host surrogate key
            SELECT h.id FROM host h WHERE h.machine_id = machine_id_param INTO host_id_var;
            -- insert a job entry
            INSERT INTO job (host_id, fx_key, created) VALUES (host_id_var, fx_key_param, now());
        END ;
        $BODY$;

        -- get number of jobs scheduled but not yet started for a host
        CREATE OR REPLACE FUNCTION pilotctl_scheduled_jobs(
            machine_id_param VARCHAR(100)
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
                WHERE h.machine_id = machine_id_param
                  -- jobs started but not completed
                  AND j.started IS NOT NULL
                  AND j.completed IS NULL
            );
            RETURN count;
        END;
        $BODY$;

        -- gets the next job for a host
        -- if no job is available then returned job_id is -1
        -- if a job is found, its status is changed from "created" to "scheduled"
        CREATE OR REPLACE FUNCTION pilotctl_get_next_job(
            machine_id_param VARCHAR(100)
        )
            RETURNS TABLE
            (
                job_id     BIGINT,
                fx_key     CHARACTER VARYING(100),
                fx_version BIGINT
            )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        DECLARE
            job_id_var     BIGINT;
            fx_key_var     CHARACTER VARYING(100);
            fx_version_var BIGINT;
        BEGIN
            -- identify oldest job that needs scheduling only if no other jobs have been already scheduled
            -- and are waiting to start
            SELECT j.id, j.fx_key, j.fx_version
            INTO job_id_var, fx_key_var, fx_version_var
            FROM job j
                     INNER JOIN host h ON h.id = j.host_id
            WHERE h.machine_id = machine_id_param
              -- job has not been picked by the service yet
              AND j.started IS NULL
              -- there are no other jobs scheduled and waiting to start for the host_key_param
              AND pilotctl_scheduled_jobs(machine_id_param) = 0
              -- older job first
            ORDER BY j.created ASC
            -- only interested in one job at a time
            LIMIT 1;

            IF FOUND THEN
                -- change the job status to scheduled
                UPDATE job SET started = NOW() WHERE id = job_id_var;
            ELSE
                -- ensure the return value is less than zero to indicate a job has not been found
                job_id_var = -1;
            END IF;
            -- return the result
            RETURN QUERY
                SELECT job_id_var, fx_key_var, fx_version_var;
        END;
        $BODY$;

        -- set a job as complete and updates status and log
        CREATE OR REPLACE FUNCTION pilotctl_complete_job(
            job_id_param BIGINT,
            log_param TEXT,
            error_param BOOLEAN
        )
            RETURNS VOID
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            UPDATE job
            SET completed = NOW(),
                log = log_param,
                error = error_param
            WHERE id = job_id_param;
        END
        $BODY$;

    END;
$$