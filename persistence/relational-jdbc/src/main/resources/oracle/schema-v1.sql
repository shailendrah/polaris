-- Licensed to the Apache Software Foundation (ASF) under one
-- or more contributor license agreements.  See the NOTICE file
-- distributed with this work for additional information
-- regarding copyright ownership.  The ASF licenses this file
-- to you under the Apache License, Version 2.0 (the
-- "License"); you may not use this file except in compliance
-- with the License.  You may obtain a copy of the License at
--
--   http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
-- KIND, either express or implied.  See the License for the
-- specific language governing permissions and limitations
-- under the License.
--
-- Schema version 1 for Apache Polaris on Oracle. Pre-v2 layout: no
-- location_without_scheme on ENTITIES, and no metrics tables (added in v4).

CREATE TABLE IF NOT EXISTS POLARIS_SCHEMA.ENTITIES (
  realm_id VARCHAR2(256) NOT NULL,
  catalog_id NUMBER(19) NOT NULL,
  id NUMBER(19) NOT NULL,
  parent_id NUMBER(19) NOT NULL,
  type_code NUMBER(10) NOT NULL,
  name VARCHAR2(256) NOT NULL,
  entity_version NUMBER(10) NOT NULL,
  sub_type_code NUMBER(10) NOT NULL,
  create_timestamp NUMBER(19),
  drop_timestamp NUMBER(19),
  purge_timestamp NUMBER(19),
  to_purge_timestamp NUMBER(19),
  last_update_timestamp NUMBER(19),
  properties CLOB,
  internal_properties CLOB,
  grant_records_version NUMBER(10) NOT NULL,
  CONSTRAINT pk_entities PRIMARY KEY (realm_id, catalog_id, id)
);

CREATE UNIQUE INDEX IF NOT EXISTS POLARIS_SCHEMA.ux_entities_parent_name_type
  ON POLARIS_SCHEMA.ENTITIES (realm_id, catalog_id, parent_id, type_code, name);

CREATE TABLE IF NOT EXISTS POLARIS_SCHEMA.GRANT_RECORDS (
  realm_id VARCHAR2(256) NOT NULL,
  securable_catalog_id NUMBER(19) NOT NULL,
  securable_id NUMBER(19) NOT NULL,
  grantee_catalog_id NUMBER(19) NOT NULL,
  grantee_id NUMBER(19) NOT NULL,
  privilege_code NUMBER(10) NOT NULL,
  CONSTRAINT pk_grant_records PRIMARY KEY (realm_id, securable_catalog_id, securable_id, grantee_catalog_id, grantee_id, privilege_code)
);

CREATE INDEX IF NOT EXISTS POLARIS_SCHEMA.ix_grant_records_grantee
  ON POLARIS_SCHEMA.GRANT_RECORDS (realm_id, grantee_catalog_id, grantee_id);

CREATE TABLE IF NOT EXISTS POLARIS_SCHEMA.POLICY_MAPPING_RECORD (
  realm_id VARCHAR2(256) NOT NULL,
  target_catalog_id NUMBER(19) NOT NULL,
  target_id NUMBER(19) NOT NULL,
  policy_type_code NUMBER(10) NOT NULL,
  policy_catalog_id NUMBER(19) NOT NULL,
  policy_id NUMBER(19) NOT NULL,
  parameters CLOB,
  CONSTRAINT pk_policy_mapping_record PRIMARY KEY (realm_id, target_catalog_id, target_id, policy_type_code, policy_catalog_id, policy_id)
);

CREATE INDEX IF NOT EXISTS POLARIS_SCHEMA.ix_policy_mapping_policy
  ON POLARIS_SCHEMA.POLICY_MAPPING_RECORD (realm_id, policy_catalog_id, policy_id);

CREATE TABLE IF NOT EXISTS POLARIS_SCHEMA.PRINCIPAL_AUTHENTICATION_DATA (
  realm_id VARCHAR2(256) NOT NULL,
  principal_id NUMBER(19) NOT NULL,
  principal_client_id VARCHAR2(256) NOT NULL,
  main_secret_hash VARCHAR2(512),
  secondary_secret_hash VARCHAR2(512),
  secret_salt VARCHAR2(512),
  CONSTRAINT pk_principal_auth PRIMARY KEY (realm_id, principal_client_id)
);

CREATE INDEX IF NOT EXISTS POLARIS_SCHEMA.ix_principal_auth_pid
  ON POLARIS_SCHEMA.PRINCIPAL_AUTHENTICATION_DATA (realm_id, principal_id);

CREATE TABLE IF NOT EXISTS POLARIS_SCHEMA.EVENTS (
  realm_id VARCHAR2(256) NOT NULL,
  catalog_id VARCHAR2(256),
  event_id VARCHAR2(256) NOT NULL,
  request_id VARCHAR2(256),
  event_type VARCHAR2(256) NOT NULL,
  timestamp_ms NUMBER(19) NOT NULL,
  principal_name VARCHAR2(512),
  resource_type VARCHAR2(64) NOT NULL,
  resource_identifier VARCHAR2(2000) NOT NULL,
  additional_properties CLOB,
  CONSTRAINT pk_events PRIMARY KEY (realm_id, event_id)
);

CREATE INDEX IF NOT EXISTS POLARIS_SCHEMA.ix_events_ts
  ON POLARIS_SCHEMA.EVENTS (realm_id, timestamp_ms);

CREATE TABLE IF NOT EXISTS POLARIS_SCHEMA.idempotency_records (
  realm_id VARCHAR2(256) NOT NULL,
  idempotency_key VARCHAR2(256) NOT NULL,
  operation_type VARCHAR2(64) NOT NULL,
  resource_id VARCHAR2(2000) NOT NULL,
  http_status NUMBER(10),
  error_subtype VARCHAR2(256),
  response_summary CLOB,
  response_headers CLOB,
  finalized_at TIMESTAMP(6),
  created_at TIMESTAMP(6) NOT NULL,
  updated_at TIMESTAMP(6) NOT NULL,
  heartbeat_at TIMESTAMP(6),
  executor_id VARCHAR2(256),
  expires_at TIMESTAMP(6) NOT NULL,
  CONSTRAINT pk_idempotency_records PRIMARY KEY (realm_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS POLARIS_SCHEMA.ix_idempotency_expires
  ON POLARIS_SCHEMA.idempotency_records (realm_id, expires_at);

CREATE TABLE IF NOT EXISTS POLARIS_SCHEMA.VERSION (
  version_value NUMBER(10) NOT NULL
);

INSERT INTO POLARIS_SCHEMA.VERSION (version_value)
SELECT 1 FROM dual WHERE NOT EXISTS (SELECT 1 FROM POLARIS_SCHEMA.VERSION);
