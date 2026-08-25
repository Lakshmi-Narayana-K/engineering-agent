-- Read-only database identity for the NKB Engineering Agent.
-- Target: Aurora MySQL. Run once against the CLUSTER (writer) endpoint; the
-- user replicates to readers automatically.
--
-- Prerequisite: IAM database authentication must be enabled on the cluster.
--   aws rds modify-db-cluster --db-cluster-identifier <CLUSTER> \
--       --enable-iam-database-authentication --apply-immediately
--
-- AWSAuthenticationPlugin means no password is ever created, stored or rotated.
-- The agent calls generate_db_auth_token() for a 15-minute credential, and
-- authorization is controlled by the rds-db:connect IAM permission, which names
-- this user specifically. Revoking IAM access revokes database access.

CREATE USER 'nkb_agent_readonly'@'%'
  IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS'
  REQUIRE SSL;

-- Scope this to the schemas the agent actually needs. `*.*` is not appropriate:
-- it would expose mysql.* and other system schemas.
GRANT SELECT ON <DB_NAME>.* TO 'nkb_agent_readonly'@'%';

-- All three products share a single connection pool -- there is no per-app
-- database routing in this codebase -- so an unbounded agent query degrades
-- backend, assessment and learning simultaneously. These limits bound that.
ALTER USER 'nkb_agent_readonly'@'%'
  WITH MAX_USER_CONNECTIONS 5
       MAX_QUERIES_PER_HOUR 2000;

FLUSH PRIVILEGES;


-- Verification -------------------------------------------------------------
--
-- SHOW GRANTS FOR 'nkb_agent_readonly'@'%';
--   Expect exactly one GRANT SELECT line and USAGE. Anything else is too much.
--
-- Then connect to the READER endpoint (hostname contains `cluster-ro-`) as this
-- user and confirm the engine refuses writes independently of the grants:
--
--   CREATE TABLE _agent_write_probe (x INT);
--   -- expect: ERROR 1290 ... --read-only option
--
-- That error is the guarantee worth having. Aurora replicas run innodb_read_only,
-- so writes fail at the engine even if the grants were wrong and even if the
-- MCP server's SQL filter were bypassed.


-- Optional: PII containment ------------------------------------------------
--
-- Every row the agent reads is transmitted to an external model API. If learner
-- PII should not leave the VPC, grant against a masked view rather than the base
-- tables and omit the blanket GRANT above:
--
--   CREATE VIEW agent_users AS
--     SELECT id, created_at, status,
--            CONCAT(LEFT(email, 2), '***@', SUBSTRING_INDEX(email, '@', -1)) AS email_masked
--     FROM users;
--   GRANT SELECT ON <DB_NAME>.agent_users TO 'nkb_agent_readonly'@'%';
