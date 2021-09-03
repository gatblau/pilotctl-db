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
            host_uuid_param CHARACTER VARYING(100)
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
            SELECT COUNT(*) FROM host WHERE host_uuid = host_uuid_param INTO host_count;
            -- if the host does not exist, insert a new entry
            IF host_count = 0 THEN
                INSERT INTO host(host_uuid, last_seen, in_service) VALUES (host_uuid_param, now(), true);
            ELSE -- otherwise, update the last_seen timestamp
                UPDATE host
                SET last_seen  = now(),
                    -- any beat revert in_service flag to true
                    in_service = true
                WHERE host_uuid = host_uuid_param;
            END IF;
            -- finally get the next job for the machine id (if any exists, if not job_id < 0)
            RETURN QUERY
                SELECT j.job_id, j.fx_key, j.fx_version
                FROM pilotctl_get_next_job(host_uuid_param) j;
        END;
        $BODY$;

        -- return host information including connection status
        CREATE OR REPLACE FUNCTION pilotctl_get_host(
            -- the interval after last ping after which a host is considered disconnected
            after INTERVAL,
            -- query filters
            org_group_param CHARACTER VARYING,
            org_param CHARACTER VARYING,
            area_param CHARACTER VARYING,
            location_param CHARACTER VARYING
        )
            RETURNS TABLE
                    (
                        machine_id CHARACTER VARYING,
                        connected  BOOLEAN,
                        since      TIMESTAMP(6) WITH TIME ZONE,
                        org_group  CHARACTER VARYING,
                        org        CHARACTER VARYING,
                        area       CHARACTER VARYING,
                        location   CHARACTER VARYING,
                        in_service BOOLEAN,
                        tag        TEXT[]
                    )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            RETURN QUERY
                SELECT h.host_uuid,
                       -- dynamically calculates connection status based on last_seen and passed-in interval
                       coalesce(h.last_seen, date_trunc('month', now()) - interval '12 month') > now() - after as connected,
                       h.last_seen,
                       h.org_group,
                       h.org,
                       h.area,
                       h.location,
                       h.in_service,
                       h.label
                FROM host h
                WHERE h.area = COALESCE(NULLIF(area_param, ''), h.area)
                  AND h.location = COALESCE(NULLIF(location_param, ''), h.location)
                  AND h.org = COALESCE(NULLIF(org_param, ''), h.org)
                  AND h.org_group = COALESCE(NULLIF(org_group_param, ''), h.org_group);
        END ;
        $BODY$;

        -- ADMISSIONS

        -- insert or update admission
        CREATE OR REPLACE FUNCTION pilotctl_set_admission(
            machine_id_param VARCHAR(100),
            org_group_param VARCHAR(100),
            org_param VARCHAR(100),
            area_param VARCHAR(100),
            location_param VARCHAR(100),
            label_param TEXT[]
        )
            RETURNS VOID
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            /* note: in_service is set to true after admission */
            INSERT INTO host (host_uuid, org_group, org, area, location, label, in_service)
            VALUES (machine_id_param, org_group_param, org_param, area_param, location_param, label_param, TRUE)
            ON CONFLICT (host_uuid)
                DO UPDATE
                SET org_group  = org_group_param,
                    org        = org_param,
                    area       = area_param,
                    location   = location_param,
                    label      = label_param,
                    in_service = TRUE;
        END ;
        $BODY$;

        -- get admission status
        CREATE OR REPLACE FUNCTION pilotctl_is_admitted(
            host_uuid_param VARCHAR(100)
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
            FROM host
                 -- there is an entry for the machine id
            WHERE host_uuid = host_uuid_param
              AND in_service = true );
            RETURN admitted;
        END ;
        $BODY$;

        -- JOBS

        -- create a new job for executing a command on a host
        CREATE OR REPLACE FUNCTION pilotctl_create_job_batch(
            name_param CHARACTER VARYING,
            desc_param CHARACTER VARYING,
            owner_param CHARACTER VARYING,
            label_param TEXT[]
        )
            RETURNS TABLE ( job_batch_Id BIGINT )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            INSERT INTO job_batch (name, description, owner, label) VALUES (name_param, desc_param, owner_param, label_param);
            RETURN QUERY select currval('job_batch_id_seq');
        END ;
        $BODY$;

        -- create a new job for executing a command on a host
        CREATE OR REPLACE FUNCTION pilotctl_create_job(
            job_batch_id_param BIGINT,
            host_uuid_param CHARACTER VARYING(100),
            fx_key_param CHARACTER VARYING(100),
            fx_version_param BIGINT
        )
            RETURNS VOID
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        DECLARE
            host_id_var BIGINT;
        BEGIN
            -- capture the host surrogate key
            SELECT h.id FROM host h WHERE h.host_uuid = host_uuid_param INTO host_id_var;
            -- if the host is not admitted
            IF host_id_var IS NULL THEN
                -- return an error
                RAISE EXCEPTION 'Host UUID % is not recognised, has it be admitted?', host_uuid_param;
            END IF;
            -- insert a job entry
            INSERT INTO job (job_batch_id, host_id, fx_key, fx_version, created)
            VALUES (job_batch_id_param, host_id_var, fx_key_param, fx_version_param, now());
        END ;
        $BODY$;

        -- get number of jobs scheduled but not yet started for a host
        CREATE OR REPLACE FUNCTION pilotctl_scheduled_jobs(
            host_uuid_param VARCHAR(100)
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
                WHERE h.host_uuid = host_uuid_param
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
            host_uuid_param VARCHAR(100)
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
            WHERE h.host_uuid = host_uuid_param
              -- job has not been picked by the service yet
              AND j.started IS NULL
              -- there are no other jobs scheduled and waiting to start for the host_key_param
              AND pilotctl_scheduled_jobs(host_uuid_param) = 0
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
                SELECT COALESCE(job_id_var, -1), COALESCE(fx_key_var, ''), COALESCE(fx_version_var, -1);
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
                log       = log_param,
                error     = error_param
            WHERE id = job_id_param;
        END
        $BODY$;

        -- pilotctl_get_job_batches query for job batches with various filtering options
        CREATE OR REPLACE FUNCTION pilotctl_get_job_batches(
            name_param CHARACTER VARYING,
            from_param TIMESTAMP,
            to_param TIMESTAMP,
            label_param TEXT[],
            owner_param CHARACTER VARYING
        )
        RETURNS TABLE (
                job_batch_id BIGINT,
                name CHARACTER VARYING,
                description TEXT,
                label TEXT[],
                created TIMESTAMP WITH TIME ZONE,
                owner CHARACTER VARYING,
                jobs BIGINT
            )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            RETURN QUERY
                SELECT jb.id,
                       jb.name,
                       jb.description,
                       jb.label,
                       jb.created,
                       jb.owner,
                       count(j.*) AS jobs
                FROM job_batch jb
                         INNER JOIN job j
                                    ON jb.id = j.job_batch_id
                WHERE
                  -- filters by job name
                    jb.name LIKE (COALESCE(NULLIF(name_param, ''), jb.name) || '%')
                  AND
                  -- filters by owner
                    jb.owner = COALESCE(NULLIF(owner_param, ''), jb.owner)
                  AND
                  -- filters by labels
                    (jb.label @> label_param OR label_param IS NULL)
                  AND
                  -- filters by date range
                    ((COALESCE(from_param, now()) <= jb.created AND COALESCE(to_param, now()) > jb.created) OR
                     (from_param IS NULL AND to_param IS NULL))
                GROUP BY (jb.id, jb.name, jb.description, jb.label, jb.created, jb.owner);
        END ;
        $BODY$;

        -- get a list of jobs filtered by org-group, group, area and location
        CREATE OR REPLACE FUNCTION pilotctl_get_jobs(
            org_group_param CHARACTER VARYING,
            org_param CHARACTER VARYING,
            area_param CHARACTER VARYING,
            location_param CHARACTER VARYING,
            batch_id_param BIGINT
        )
            RETURNS TABLE
                    (
                        id           BIGINT,
                        host_uuid    CHARACTER VARYING,
                        job_batch_id BIGINT,
                        fx_key       CHARACTER VARYING,
                        fx_version   BIGINT,
                        created      TIMESTAMP(6) WITH TIME ZONE,
                        started      TIMESTAMP(6) WITH TIME ZONE,
                        completed    TIMESTAMP(6) WITH TIME ZONE,
                        log          TEXT,
                        error        BOOLEAN,
                        org_group    CHARACTER VARYING,
                        org          CHARACTER VARYING,
                        area         CHARACTER VARYING,
                        location     CHARACTER VARYING,
                        tag          TEXT[]
                    )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            RETURN QUERY
                SELECT j.id,
                       h.host_uuid,
                       j.job_batch_id,
                       j.fx_key,
                       j.fx_version,
                       j.created,
                       j.started,
                       j.completed,
                       j.log,
                       j.error,
                       h.org_group,
                       h.org,
                       h.area,
                       h.location,
                       h.label
                FROM job j
                         INNER JOIN host h ON h.id = j.host_id
                WHERE h.area = COALESCE(NULLIF(area_param, ''), h.area)
                  AND h.location = COALESCE(NULLIF(location_param, ''), h.location)
                  AND h.org = COALESCE(NULLIF(org_param, ''), h.org)
                  AND h.org_group = COALESCE(NULLIF(org_group_param, ''), h.org_group)
                  AND j.job_batch_id = COALESCE(batch_id_param, j.job_batch_id);
        END ;
        $BODY$;

    END;
$$