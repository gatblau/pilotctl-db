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
        -- BEAT
        ---------------------------------------------------------------------------
        IF NOT EXISTS(SELECT relname FROM pg_class WHERE relname = 'beat')
        THEN
            CREATE SEQUENCE beat_id_seq
                INCREMENT 1
                START 1000
                MINVALUE 1000
                MAXVALUE 9223372036854775807
                CACHE 1;

            ALTER SEQUENCE beat_id_seq
                OWNER TO onix;

            CREATE TABLE "beat"
            (
                id      BIGINT                 NOT NULL DEFAULT nextval('beat_id_seq'::regclass),
                key     CHARACTER VARYING(100) NOT NULL,
                updated TIMESTAMP(6) WITH TIME ZONE     DEFAULT CURRENT_TIMESTAMP(6),
                CONSTRAINT beat_id_pk PRIMARY KEY (id),
                CONSTRAINT beat_key_uc UNIQUE (key)
            ) WITH (OIDS = FALSE)
              TABLESPACE pg_default;

            ALTER TABLE "beat"
                OWNER to onix;
        END IF;
    END;
$$
