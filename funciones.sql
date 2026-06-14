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

-- -----------------------------------------------------------------------------
-- 2. Trigger b - autopoblar vendedores (sobre SUBASTA)
-- -----------------------------------------------------------------------------
-- Al insertar una subasta, si el email_vendedor no existe en USUARIO se inserta;
-- si ya existe, no hace nada. Es BEFORE INSERT para que la FK email_vendedor ->
-- usuario quede satisfecha al momento de insertar la subasta.
CREATE OR REPLACE FUNCTION trg_subasta_autopoblar_vendedor()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE email = NEW.email_vendedor) THEN
        INSERT INTO usuario(email) VALUES (NEW.email_vendedor);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER subasta_bi
BEFORE INSERT ON subasta
FOR EACH ROW
EXECUTE FUNCTION trg_subasta_autopoblar_vendedor();

-- -----------------------------------------------------------------------------
-- 3. Trigger c - validar e insertar ofertas (sobre OFERTA)
-- -----------------------------------------------------------------------------
-- Acciones en el orden exacto que pide el enunciado:
--   (1) autopoblar USUARIO con email_usuario si no existe
--   (2) validar que la subasta exista y fecha_hora en [fecha_inicio, fecha_cierre]
--   (3) el oferente no puede ser el vendedor
--   (4) el oferente no puede haber hecho la ultima oferta (no dos seguidas)
--   (5) validar monto: 1a oferta >= precio_base; siguiente >= max + incremento_min
--   (6) asignar nro_oferta correlativo
-- Cada rechazo lanza RAISE EXCEPTION (deshace la operacion).
CREATE OR REPLACE FUNCTION trg_oferta_validar()
RETURNS TRIGGER AS $$
DECLARE
    v_sub        subasta%ROWTYPE;
    v_max_monto  NUMERIC(12,2);
    v_max_nro    INTEGER;
    v_count      INTEGER;
    v_ult_email  VARCHAR(255);
BEGIN
    -- (1) Autopoblar usuario oferente
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE email = NEW.email_usuario) THEN
        INSERT INTO usuario(email) VALUES (NEW.email_usuario);
    END IF;

    -- (2) La subasta debe existir
    SELECT * INTO v_sub FROM subasta WHERE id = NEW.id_subasta;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La subasta % no existe.', NEW.id_subasta;
    END IF;

    -- (2b) fecha_hora dentro del periodo activo [inicio, cierre]
    IF NEW.fecha_hora < v_sub.fecha_inicio OR NEW.fecha_hora > v_sub.fecha_cierre THEN
        RAISE EXCEPTION 'La subasta % no esta activa en % (periodo % a %).',
            NEW.id_subasta, NEW.fecha_hora, v_sub.fecha_inicio, v_sub.fecha_cierre;
    END IF;

    -- (3) El oferente no puede ser el vendedor
    IF NEW.email_usuario = v_sub.email_vendedor THEN
        RAISE EXCEPTION 'El vendedor % no puede pujar en su propia subasta %.',
            NEW.email_usuario, NEW.id_subasta;
    END IF;

    -- Estado actual de las ofertas de la subasta
    SELECT COALESCE(MAX(monto), 0), COALESCE(MAX(nro_oferta), 0), COUNT(*)
      INTO v_max_monto, v_max_nro, v_count
      FROM oferta WHERE id_subasta = NEW.id_subasta;

    -- (4) No dos ofertas consecutivas del mismo usuario
    IF v_count > 0 THEN
        SELECT email_usuario INTO v_ult_email
          FROM oferta
         WHERE id_subasta = NEW.id_subasta
         ORDER BY nro_oferta DESC
         LIMIT 1;
        IF v_ult_email = NEW.email_usuario THEN
            RAISE EXCEPTION 'El usuario % ya realizo la ultima oferta de la subasta % (debe esperar a otro oferente).',
                NEW.email_usuario, NEW.id_subasta;
        END IF;
    END IF;

    -- (5) Validar monto
    IF v_count = 0 THEN
        IF NEW.monto < v_sub.precio_base THEN
            RAISE EXCEPTION 'La primera oferta (%) no alcanza el precio base (%).',
                NEW.monto, v_sub.precio_base;
        END IF;
    ELSE
        IF NEW.monto < v_max_monto + v_sub.incremento_min THEN
            RAISE EXCEPTION 'El monto (%) debe superar la mayor oferta (%) en al menos % (minimo requerido: %).',
                NEW.monto, v_max_monto, v_sub.incremento_min, v_max_monto + v_sub.incremento_min;
        END IF;
    END IF;

    -- (6) Asignar nro_oferta correlativo
    NEW.nro_oferta := v_max_nro + 1;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER oferta_bi
BEFORE INSERT ON oferta
FOR EACH ROW
EXECUTE FUNCTION trg_oferta_validar();
