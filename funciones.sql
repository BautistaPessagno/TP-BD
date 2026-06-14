-- =============================================================================
-- TP Especial - Base de Datos I (1C 2026)
-- Sistema de subastas online en PostgreSQL (PSM + Triggers)
--
-- Script unico y ejecutable de cero: crea las tablas, los triggers y las
-- funciones. El orden es importante: primero el DDL, luego los triggers de
-- autopoblado/validacion y finalmente las funciones de cierre y reporte.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Tablas (DDL)
-- -----------------------------------------------------------------------------
-- Limpieza para reruns durante el desarrollo.
DROP TABLE IF EXISTS oferta   CASCADE;
DROP TABLE IF EXISTS subasta  CASCADE;
DROP TABLE IF EXISTS usuario  CASCADE;

CREATE TABLE usuario (
    email VARCHAR(255) PRIMARY KEY
);

CREATE TABLE subasta (
    id              INTEGER       PRIMARY KEY,
    descripcion     VARCHAR(255)  NOT NULL,
    categoria       VARCHAR(100)  NOT NULL,
    email_vendedor  VARCHAR(255)  NOT NULL REFERENCES usuario(email),
    fecha_inicio    TIMESTAMP     NOT NULL,
    fecha_cierre    TIMESTAMP     NOT NULL,
    precio_base     NUMERIC(12,2) NOT NULL CHECK (precio_base    > 0),
    incremento_min  NUMERIC(12,2) NOT NULL CHECK (incremento_min > 0),
    email_ganador   VARCHAR(255)  REFERENCES usuario(email),   -- NULL hasta el cierre
    monto_ganador   NUMERIC(12,2),                              -- NULL hasta el cierre
    CHECK (fecha_cierre > fecha_inicio)
);

CREATE TABLE oferta (
    id_subasta    INTEGER       NOT NULL REFERENCES subasta(id),
    nro_oferta    INTEGER       NOT NULL,                 -- lo asigna el trigger (no viene del CSV)
    email_usuario VARCHAR(255)  NOT NULL REFERENCES usuario(email),
    fecha_hora    TIMESTAMP     NOT NULL,
    monto         NUMERIC(12,2) NOT NULL,
    PRIMARY KEY (id_subasta, nro_oferta)                 -- entidad debil
);
