/*
    Onix Pilot Control Service - Copyright (c) 2018-Present by www.gatblau.org

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
                id           BIGINT                 NOT NULL DEFAULT nextval('host_id_seq'::regclass),
                -- the host unique identifier
                host_uuid    CHARACTER VARYING(100),
                -- the mac address of the host primary interface
                mac_address  CHARACTER VARYING(100),
                -- the natural key for the organisation group using the host
                org_group    CHARACTER VARYING(100),
                -- the natural key for the organisation using the host
                org          CHARACTER VARYING(100),
                -- the natural key for the region under which the host is deployed
                area         CHARACTER VARYING(100),
                -- the natural key for the physical location under which the host is deployed
                location     CHARACTER VARYING(100),
                -- when was the pilot last beat?
                last_seen    TIMESTAMP(6) WITH TIME ZONE,
                -- is the host supposed to be working or is it powered off / in transit / stored away?
                in_service   BOOLEAN,
                -- host labels
                label        TEXT[],
                -- the host local ip address
                ip           CHARACTER VARYING(100),
                -- the hostname
                hostname     CHARACTER VARYING(100),
                -- link tag used to group hosts together
                link         CHARACTER VARYING(16),
                -- the date the host was decommissioned, null if the host is active
                decom_date   TIMESTAMP(6) WITH TIME ZONE,
                cve_critical INTEGER,
                cve_high     INTEGER,
                cve_medium   INTEGER,
                cve_low      INTEGER,
                CONSTRAINT host_id_pk PRIMARY KEY (id),
                CONSTRAINT host_key_uc UNIQUE (host_uuid),
                CONSTRAINT mac_address_uc UNIQUE (mac_address)
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            -- Generalized Inverted Index.
            -- GIN is designed for handling cases where the items to be indexed are composite values,
            -- and the queries to be handled by the index need to search for element values that appear within the composite items
            CREATE INDEX host_label_ix
                ON host USING gin (label COLLATE pg_catalog."default")
                TABLESPACE pg_default;

            ALTER TABLE "host"
                OWNER to pilotctl;
        END IF;

        ---------------------------------------------------------------------------
        -- JOB_BATCH (the definition for a job batch, a group of jobs executed on multiple hosts)
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'job_batch')
        THEN
            CREATE SEQUENCE job_batch_id_seq
                INCREMENT 1
                START 1000
                MINVALUE 1000
                MAXVALUE 9223372036854775807
                CACHE 1;

            ALTER SEQUENCE job_batch_id_seq
                OWNER TO pilotctl;

            CREATE TABLE "job_batch"
            (
                id      BIGINT NOT NULL             DEFAULT nextval('job_batch_id_seq'::regclass),
                -- when the job reference was created
                created TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP(6),
                -- a name for the reference (not unique)
                name    VARCHAR(150),
                -- any non-mandatory notes associated with the batch
                notes   TEXT,
                -- who created the job batch
                owner   VARCHAR(150),
                -- one or more search labels associated to the reference
                label   TEXT[],
                CONSTRAINT job_batch_id_pk PRIMARY KEY (id)
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            -- Generalized Inverted Index.
            -- GIN is designed for handling cases where the items to be indexed are composite values,
            -- and the queries to be handled by the index need to search for element values that appear within the composite items
            CREATE INDEX job_batch_label_ix
                ON job_batch USING gin (label COLLATE pg_catalog."default")
                TABLESPACE pg_default;

            ALTER TABLE "job_batch"
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
                id           BIGINT NOT NULL             DEFAULT nextval('job_id_seq'::regclass),
                -- the surrogate key of the host where the job should be executed
                host_id      BIGINT NOT NULL,
                -- the natural key of the configuration item for the artisan function to execute
                fx_key       CHARACTER VARYING(150),
                -- version of the fx config item in Onix used for the job
                fx_version   BIGINT NOT NULL,
                -- the client has requested the job to be executed
                created      TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP(6),
                -- the service has delivered the job to the relevant remote pilot
                started      TIMESTAMP(6) WITH TIME ZONE,
                -- the service has received the completion information from the relevant remote pilot
                completed    TIMESTAMP(6) WITH TIME ZONE,
                -- the remote execution log
                log          TEXT,
                -- true if the job has failed
                error        BOOLEAN,
                -- the foreign key to the job batch
                job_batch_id BIGINT NOT NULL,
                CONSTRAINT job_id_pk PRIMARY KEY (id),
                CONSTRAINT job_host_id_fk FOREIGN KEY (host_id)
                    REFERENCES host (id) MATCH SIMPLE
                    ON UPDATE NO ACTION
                    ON DELETE CASCADE,
                CONSTRAINT job_batch_id_fk FOREIGN KEY (job_batch_id)
                    REFERENCES job_batch (id) MATCH SIMPLE
                    ON UPDATE NO ACTION
                    ON DELETE CASCADE
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "job"
                OWNER to pilotctl;
        END IF;


        ---------------------------------------------------------------------------
        -- CVE (stores Common Vulnerability & Exploits (CVE) definitions)
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'cve')
        THEN
            CREATE TABLE "cve"
            (
                id                CHARACTER VARYING(30) NOT NULL,
                summary           TEXT,
                fixed             BOOLEAN,
                cvss_score        NUMERIC(2,1),
                cvss_type         CHARACTER VARYING(20),
                cvss_severity     CHARACTER VARYING(20),
                cvss_vector       CHARACTER VARYING(20),
                primary_source    TEXT[],
                mitigations       TEXT[],
                patch_urls        TEXT[],
                confidence        TEXT[],
                cpe               TEXT[],
                reference         JSONB,
                CONSTRAINT cve_id_pk PRIMARY KEY (id)
            ) WITH (OIDS = FALSE)
            TABLESPACE pg_default;

            ALTER TABLE "cve"
                OWNER to pilotctl;
        END IF;

        ---------------------------------------------------------------------------
        -- CVE_HOST (stores links between CVEs and Hosts)
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'cve_host')
        THEN
            CREATE TABLE "cve_host"
            (
                cve_id            CHARACTER VARYING(30) NOT NULL,
                host_uuid         CHARACTER VARYING(100) NOT NULL,
                scan_date         TIMESTAMP(6) WITH TIME ZONE,
                CONSTRAINT cve_host_pk PRIMARY KEY (cve_id, host_uuid)
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "cve_host"
                OWNER to pilotctl;
        END IF;

        ---------------------------------------------------------------------------
        -- CVE_PAC (stores affected CVE packages)
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'cve_pac')
        THEN
            CREATE TABLE "cve_pac"
            (
                cve_id            CHARACTER VARYING(30) NOT NULL,
                package_name      CHARACTER VARYING(100) NOT NULL,
                fixed             BOOLEAN,
                fixed_in          CHARACTER VARYING(100),
                CONSTRAINT cve_pac_pk PRIMARY KEY (cve_id, package_name)
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "cve_pac"
                OWNER to pilotctl;
        END IF;
    END;
$$
