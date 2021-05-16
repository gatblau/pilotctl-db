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
                OWNER TO rem;

            CREATE TABLE "host"
            (
                id        BIGINT                 NOT NULL DEFAULT nextval('host_id_seq'::regclass),
                key       CHARACTER VARYING(100) NOT NULL,
                last_seen TIMESTAMP(6) WITH TIME ZONE,
                CONSTRAINT host_id_pk PRIMARY KEY (id),
                CONSTRAINT host_key_uc UNIQUE (key)
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "host"
                OWNER to rem;
        END IF;

        ---------------------------------------------------------------------------
        -- COMM (store the definition of commands that can be executed on remote hosts)
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'comm')
        THEN
            CREATE SEQUENCE comm_id_seq
                INCREMENT 1
                START 1000
                MINVALUE 1000
                MAXVALUE 9223372036854775807
                CACHE 1;

            ALTER SEQUENCE comm_id_seq
                OWNER TO rem;

            CREATE TABLE "comm"
            (
                id      BIGINT                 NOT NULL DEFAULT nextval('comm_id_seq'::regclass),
                package CHARACTER VARYING(100) NOT NULL,
                fx      CHARACTER VARYING(100) NOT NULL,
                input   HSTORE,
                created TIMESTAMP(6) WITH TIME ZONE     DEFAULT CURRENT_TIMESTAMP(6),
                updated TIMESTAMP(6) WITH TIME ZONE     DEFAULT CURRENT_TIMESTAMP(6),
                CONSTRAINT comm_id_pk PRIMARY KEY (id)
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "comm"
                OWNER to rem;
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
                OWNER TO rem;

            CREATE TABLE "job"
            (
                id        BIGINT NOT NULL             DEFAULT nextval('job_id_seq'::regclass),
                host_id   BIGINT NOT NULL,
                comm_id   BIGINT NOT NULL,
                result    TEXT,
                created   TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP(6),
                started   TIMESTAMP(6) WITH TIME ZONE,
                completed TIMESTAMP(6) WITH TIME ZONE,
                CONSTRAINT job_id_pk PRIMARY KEY (id),
                CONSTRAINT job_host_id_fk FOREIGN KEY (host_id)
                    REFERENCES host (id) MATCH SIMPLE
                    ON UPDATE NO ACTION
                    ON DELETE CASCADE,
                CONSTRAINT job_comm_id_fk FOREIGN KEY (comm_id)
                    REFERENCES comm (id) MATCH SIMPLE
                    ON UPDATE NO ACTION
                    ON DELETE CASCADE
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "job"
                OWNER to rem;
        END IF;

        ---------------------------------------------------------------------------
        -- EVENT (host events)
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'event')
        THEN
            CREATE SEQUENCE event_id_seq
                INCREMENT 1
                START 1000
                MINVALUE 1000
                MAXVALUE 9223372036854775807
                CACHE 1;

            ALTER SEQUENCE event_id_seq
                OWNER TO rem;

            CREATE TABLE "event"
            (
                id        BIGINT                 NOT NULL DEFAULT nextval('event_id_seq'::regclass),
                type      SMALLINT,
                time      TIMESTAMP(6) WITH TIME ZONE,
                host_id   BIGINT,
                CONSTRAINT event_id_pk PRIMARY KEY (id),
                CONSTRAINT event_host_id_fk FOREIGN KEY (host_id)
                    REFERENCES host (id) MATCH SIMPLE
                    ON UPDATE NO ACTION
                    ON DELETE CASCADE
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "event"
                OWNER to rem;
        END IF;

        ---------------------------------------------------------------------------
        -- EVENT_CHANGE
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'event_change')
        THEN
            CREATE TABLE event_change
            (
                operation CHAR(1)   NOT NULL,
                changed   TIMESTAMP NOT NULL,
                id        BIGINT,
                type      SMALLINT,
                time      TIMESTAMP(6) WITH TIME ZONE,
                host_id   BIGINT
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            CREATE OR REPLACE FUNCTION rem_change_event() RETURNS TRIGGER AS
            $rem_change_event$
            BEGIN
                IF (TG_OP = 'DELETE') THEN
                    INSERT INTO event_change SELECT 'D', now(), OLD.*;
                    RETURN OLD;
                ELSIF (TG_OP = 'UPDATE') THEN
                    INSERT INTO event_change SELECT 'U', now(), NEW.*;
                    RETURN NEW;
                ELSIF (TG_OP = 'INSERT') THEN
                    INSERT INTO event_change SELECT 'I', now(), NEW.*;
                    RETURN NEW;
                END IF;
                RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $rem_change_event$ LANGUAGE plpgsql;

            CREATE TRIGGER event_change
                AFTER INSERT OR UPDATE OR DELETE
                ON event
                FOR EACH ROW
            EXECUTE PROCEDURE rem_change_event();

            ALTER TABLE event_change
                OWNER to rem;
        END IF;
    END;
$$
