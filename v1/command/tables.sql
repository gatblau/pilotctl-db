/*
    Onix Pilot Remote Control Service - Copyright (c) 2018-2021 by www.gatblau.org

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
                id        BIGINT                 NOT NULL DEFAULT nextval('host_id_seq'::regclass),
                key       CHARACTER VARYING(100) NOT NULL,
                customer  CHARACTER VARYING(100),
                region    CHARACTER VARYING(100),
                location  CHARACTER VARYING(100),
                last_seen TIMESTAMP(6) WITH TIME ZONE,
                CONSTRAINT host_id_pk PRIMARY KEY (id),
                CONSTRAINT host_key_uc UNIQUE (key)
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "host"
                OWNER to pilotctl;
        END IF;

        ---------------------------------------------------------------------------
        -- COMMAND (store the definition of commands that can be executed on remote hosts)
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'command')
        THEN
            CREATE SEQUENCE command_id_seq
                INCREMENT 1
                START 1000
                MINVALUE 1000
                MAXVALUE 9223372036854775807
                CACHE 1;

            ALTER SEQUENCE command_id_seq
                OWNER TO pilotctl;

            CREATE TABLE "command"
            (
                id          BIGINT                 NOT NULL DEFAULT nextval('command_id_seq'::regclass),
                name        CHARACTER VARYING(100) NOT NULL,
                description TEXT,
                package     CHARACTER VARYING(100) NOT NULL,
                fx          CHARACTER VARYING(100) NOT NULL,
                input       JSONB,
                created     TIMESTAMP(6) WITH TIME ZONE     DEFAULT CURRENT_TIMESTAMP(6),
                updated     TIMESTAMP(6) WITH TIME ZONE     DEFAULT CURRENT_TIMESTAMP(6),
                CONSTRAINT command_id_pk PRIMARY KEY (id),
                CONSTRAINT command_name_uc UNIQUE (name)
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "command"
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
                id        BIGINT NOT NULL             DEFAULT nextval('job_id_seq'::regclass),
                host_id   BIGINT NOT NULL,
                command_id   BIGINT NOT NULL,
                result    TEXT,
                created   TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP(6),
                started   TIMESTAMP(6) WITH TIME ZONE,
                completed TIMESTAMP(6) WITH TIME ZONE,
                CONSTRAINT job_id_pk PRIMARY KEY (id),
                CONSTRAINT job_host_id_fk FOREIGN KEY (host_id)
                    REFERENCES host (id) MATCH SIMPLE
                    ON UPDATE NO ACTION
                    ON DELETE CASCADE,
                CONSTRAINT job_comm_id_fk FOREIGN KEY (command_id)
                    REFERENCES command (id) MATCH SIMPLE
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
                since TIMESTAMP(6) WITH TIME ZONE,
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
                since TIMESTAMP(6) WITH TIME ZONE
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

        ---------------------------------------------------------------------------
        -- ADMISSION (hosts authorised for management)
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'admission')
        THEN
            CREATE TABLE "admission"
            (
                host_key VARCHAR(100),
                active   BOOLEAN,
                tag      TEXT[],
                CONSTRAINT admission_host_key_pk PRIMARY KEY (host_key)
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "admission"
                OWNER to pilotctl;
        END IF;
    END;
$$
