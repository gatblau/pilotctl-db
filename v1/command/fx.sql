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
        -- inserts or updates the last_seen timestamp for a host
        CREATE OR REPLACE FUNCTION rem_beat(
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

        -- return all hosts updated after the specified since time
        CREATE OR REPLACE FUNCTION rem_get_host_seen(
            since TIMESTAMP(6) WITH TIME ZONE
        )
            RETURNS TABLE
                    (
                        key       CHARACTER VARYING,
                        last_seen TIMESTAMP(6) WITH TIME ZONE
                    )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            RETURN QUERY SELECT h.key, h.last_seen FROM host h WHERE h.last_seen BETWEEN since AND now();
        END;
        $BODY$;

        -- get a list of hosts since a time with their connection status
        CREATE OR REPLACE FUNCTION rem_get_host_status(
            since TIMESTAMP(6) WITH TIME ZONE
        )
            RETURNS TABLE
                    (
                        key       CHARACTER VARYING,
                        last_seen TIMESTAMP(6) WITH TIME ZONE,
                        status    BOOLEAN
                    )
            LANGUAGE 'plpgsql'
            COST 100
            VOLATILE
        AS
        $BODY$
        BEGIN
            RETURN QUERY
                SELECT h.key,
                       h.last_seen,
                       CASE
                           WHEN h.last_seen > since THEN TRUE
                           ELSE FALSE
                           END connected
                FROM host h
                WHERE h.last_seen BETWEEN since AND now();
        END;
        $BODY$;

        -- record server side connected/disconnected events using information in host table
        CREATE OR REPLACE FUNCTION rem_record_conn_status(
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
                last_seen=h.last_seen
            FROM host h
            LEFT JOIN status s
              ON s.host_id = h.id
            WHERE s.host_id IS NOT NULL
              AND s.connected <> CASE WHEN h.last_seen < now() - after THEN false ELSE true END;
        END ;
        $BODY$;
    END
$$