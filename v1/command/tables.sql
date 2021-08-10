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
        ---------------------------------------------------------------------------
        -- HOST (store the last seen timestamp received from a host)
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'host')
        THEN
            CREATE SEQUENCE host_id_seq
                INCREMENT 1
                START 1000
                MINVALUE 1000
                MAXVALUE 9223372036854775807
                CACHE 1;

            ALTER SEQUENCE host_id_seq
                OWNER TO pilotctl;

            CREATE TABLE "host"
            (
                -- the host surrogate key
                id         BIGINT                 NOT NULL DEFAULT nextval('host_id_seq'::regclass),
                -- the host machine id
                machine_id CHARACTER VARYING(100) NOT NULL,
                -- the natural key for the organisation group using the host
                org_group  CHARACTER VARYING(100),
                -- the natural key for the organisation using the host
                org        CHARACTER VARYING(100),
                -- the natural key for the region under which the host is deployed
                area       CHARACTER VARYING(100),
                -- the natural key for the physical location under which the host is deployed
                location   CHARACTER VARYING(100),
                -- when was the pilot last beat?
                last_seen  TIMESTAMP(6) WITH TIME ZONE,
                -- is the host supposed to be working or is it powered off / in transit / stored away?
                in_service BOOLEAN,
                -- host tags
                tag        TEXT[],
                CONSTRAINT host_id_pk PRIMARY KEY (id),
                CONSTRAINT host_key_uc UNIQUE (machine_id)
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "host"
                OWNER to pilotctl;
        END IF;

        ---------------------------------------------------------------------------
        -- JOB (log status of commands executed on remote hosts)
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'job')
        THEN
            CREATE SEQUENCE job_id_seq
                INCREMENT 1
                START 1000
                MINVALUE 1000
                MAXVALUE 9223372036854775807
                CACHE 1;

            ALTER SEQUENCE job_id_seq
                OWNER TO pilotctl;

            CREATE TABLE "job"
            (
                id         BIGINT NOT NULL             DEFAULT nextval('job_id_seq'::regclass),
                -- the surrogate key of the host where the job should be executed
                host_id    BIGINT NOT NULL,
                -- the natural key of the configuration item for the artisan function to execute
                fx_key     CHARACTER VARYING(150),
                -- version of the fx config item in Onix used for the job
                fx_version BIGINT NOT NULL,
                -- the client has requested the job to be executed
                created    TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP(6),
                -- the service has delivered the job to the relevant remote pilot
                started    TIMESTAMP(6) WITH TIME ZONE,
                -- the service has received the completion information from the relevant remote pilot
                completed  TIMESTAMP(6) WITH TIME ZONE,
                -- the remote execution log
                log        TEXT,
                -- true if the job has failed
                error      BOOLEAN,
                -- a job reference to group all individual host executions under the same requester reference
                ref        CHARACTER VARYING(150),
                CONSTRAINT job_id_pk PRIMARY KEY (id),
                CONSTRAINT job_host_id_fk FOREIGN KEY (host_id)
                    REFERENCES host (id) MATCH SIMPLE
                    ON UPDATE NO ACTION
                    ON DELETE CASCADE
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "job"
                OWNER to pilotctl;
        END IF;

        ---------------------------------------------------------------------------
        -- STATUS (host connectivity)
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'status')
        THEN
            CREATE TABLE "status"
            (
                host_id   BIGINT,
                connected BOOLEAN,
                since     TIMESTAMP(6) WITH TIME ZONE,
                CONSTRAINT status_host_id_pk PRIMARY KEY (host_id),
                CONSTRAINT status_host_id_fk FOREIGN KEY (host_id)
                    REFERENCES host (id) MATCH SIMPLE
                    ON UPDATE NO ACTION
                    ON DELETE CASCADE
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "status"
                OWNER to pilotctl;
        END IF;

        ---------------------------------------------------------------------------
        -- STATUS_HISTORY
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'status_history')
        THEN
            CREATE TABLE status_history
            (
                operation CHAR(1)   NOT NULL,
                changed   TIMESTAMP NOT NULL,
                host_id   BIGINT,
                connected BOOLEAN,
                since     TIMESTAMP(6) WITH TIME ZONE
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            CREATE OR REPLACE FUNCTION pilotctl_change_status() RETURNS TRIGGER AS
            $pilotctl_change_status$
            BEGIN
                IF (TG_OP = 'DELETE') THEN
                    INSERT INTO status_history SELECT 'D', now(), OLD.*;
                    RETURN OLD;
                ELSIF (TG_OP = 'UPDATE') THEN
                    INSERT INTO status_history SELECT 'U', now(), NEW.*;
                    RETURN NEW;
                ELSIF (TG_OP = 'INSERT') THEN
                    INSERT INTO status_history SELECT 'I', now(), NEW.*;
                    RETURN NEW;
                END IF;
                RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $pilotctl_change_status$ LANGUAGE plpgsql;

            CREATE TRIGGER status_change
                AFTER INSERT OR UPDATE OR DELETE
                ON status
                FOR EACH ROW
            EXECUTE PROCEDURE pilotctl_change_status();

            ALTER TABLE status_history
                OWNER to pilotctl;
        END IF;
    END;
$$
