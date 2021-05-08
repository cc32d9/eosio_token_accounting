CREATE DATABASE eosio_token_accounting;

CREATE USER 'eosio_token_accounting'@'localhost' IDENTIFIED BY 'De3PhooL';
GRANT ALL ON eosio_token_accounting.* TO 'eosio_token_accounting'@'localhost';
grant SELECT on eosio_token_accounting.* to 'eosio_token_accounting_ro'@'%' identified by 'eosio_token_accounting_ro';

use eosio_token_accounting;

CREATE TABLE SYNC
(
 network           VARCHAR(15) PRIMARY KEY,
 block_num         BIGINT NOT NULL
) ENGINE=InnoDB;


