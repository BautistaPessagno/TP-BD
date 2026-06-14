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

-- -----------------------------------------------------------------------------
-- 5. Funcion cerrar_subasta(p_id) - procesar el cierre y asignar ganador
-- -----------------------------------------------------------------------------
-- Valida que la subasta exista, que su plazo haya vencido (fecha_cierre <= now())
-- y que no tenga ganador asignado. Si pasa, toma la mayor oferta (desempate por
-- nro_oferta mas bajo) y setea email_ganador / monto_ganador. Si cerro sin
-- ofertas, termina sin error y sin modificar (idempotente: re-invocar no falla).
CREATE OR REPLACE FUNCTION cerrar_subasta(p_id INTEGER)
RETURNS VOID AS $$
DECLARE
    v_sub    subasta%ROWTYPE;
    v_email  VARCHAR(255);
    v_monto  NUMERIC(12,2);
BEGIN
    SELECT * INTO v_sub FROM subasta WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La subasta % no existe.', p_id;
    END IF;

    IF v_sub.fecha_cierre > now() THEN
        RAISE EXCEPTION 'La subasta % todavia esta abierta (cierra %).', p_id, v_sub.fecha_cierre;
    END IF;

    IF v_sub.email_ganador IS NOT NULL THEN
        RAISE EXCEPTION 'La subasta % ya fue cerrada con ganador %.', p_id, v_sub.email_ganador;
    END IF;

    -- Mayor oferta (desempate por nro_oferta mas bajo = la mas temprana en alcanzar el maximo)
    SELECT email_usuario, monto INTO v_email, v_monto
      FROM oferta
     WHERE id_subasta = p_id
     ORDER BY monto DESC, nro_oferta ASC
     LIMIT 1;

    IF NOT FOUND THEN
        RETURN;  -- cerro sin ofertas: no se modifica nada, sin error
    END IF;

    UPDATE subasta
       SET email_ganador = v_email,
           monto_ganador = v_monto
     WHERE id = p_id;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 6. Funcion reporte_subastas(p_desde, p_categoria) - reporte por categoria
-- -----------------------------------------------------------------------------
-- Recorre con un cursor explicito las subastas con fecha_cierre >= p_desde
-- (opcionalmente filtradas por categoria), ordenadas por categoria (alfabetico)
-- y por id. Imprime con RAISE NOTICE: encabezado, un bloque por categoria, un
-- renglon por subasta (ganador y monto si existe, o cantidad de ofertas),
-- subtotal por categoria y total general. Si no hay subastas, no imprime nada.
CREATE OR REPLACE FUNCTION reporte_subastas(p_desde DATE, p_categoria VARCHAR DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
    cur CURSOR FOR
        SELECT id, descripcion, categoria, precio_base, email_ganador, monto_ganador
          FROM subasta
         WHERE fecha_cierre >= p_desde
           AND (p_categoria IS NULL OR categoria = p_categoria)
         ORDER BY categoria ASC, id ASC;
    rec        RECORD;
    v_hay      BOOLEAN := FALSE;
    v_cat      VARCHAR := NULL;
    v_ofertas  INTEGER;
    -- contadores por categoria
    c_sub INTEGER; c_gan INTEGER; c_rec NUMERIC(14,2);
    -- contadores totales
    t_sub INTEGER := 0; t_gan INTEGER := 0; t_rec NUMERIC(14,2) := 0;
BEGIN
    OPEN cur;
    LOOP
        FETCH cur INTO rec;
        EXIT WHEN NOT FOUND;

        -- Encabezado (solo si hay al menos una fila)
        IF NOT v_hay THEN
            RAISE NOTICE '====== REPORTE DE SUBASTAS ======';
            IF p_categoria IS NOT NULL THEN
                RAISE NOTICE '   Categoría: %', p_categoria;
            END IF;
            RAISE NOTICE '   Desde: %', p_desde;
            v_hay := TRUE;
        END IF;

        -- Cambio de categoria: cerrar subtotal anterior y abrir bloque nuevo
        IF v_cat IS DISTINCT FROM rec.categoria THEN
            IF v_cat IS NOT NULL THEN
                RAISE NOTICE '   -- subtotal %: % subastas, % con ganador, $ % recaudado',
                    v_cat, c_sub, c_gan, c_rec;
            END IF;
            v_cat := rec.categoria;
            c_sub := 0; c_gan := 0; c_rec := 0;
            RAISE NOTICE '';
            RAISE NOTICE '== Categoría: % ==', rec.categoria;
        END IF;

        -- Cantidad de ofertas de la subasta (se muestra siempre)
        SELECT COUNT(*) INTO v_ofertas FROM oferta WHERE id_subasta = rec.id;

        -- Renglon de la subasta
        IF rec.email_ganador IS NOT NULL THEN
            RAISE NOTICE '   [#%] % - base $ % -> ganador % por $ % (% ofertas)',
                rec.id, rec.descripcion, rec.precio_base, rec.email_ganador, rec.monto_ganador, v_ofertas;
            c_gan := c_gan + 1;  t_gan := t_gan + 1;
            c_rec := c_rec + rec.monto_ganador;  t_rec := t_rec + rec.monto_ganador;
        ELSE
            RAISE NOTICE '   [#%] % - base $ % -> sin ganador asignado (% ofertas)',
                rec.id, rec.descripcion, rec.precio_base, v_ofertas;
        END IF;
        c_sub := c_sub + 1;  t_sub := t_sub + 1;
    END LOOP;

    -- Subtotal de la ultima categoria
    IF v_cat IS NOT NULL THEN
        RAISE NOTICE '   -- subtotal %: % subastas, % con ganador, $ % recaudado',
            v_cat, c_sub, c_gan, c_rec;
    END IF;

    -- Total general (solo si hubo datos)
    IF v_hay THEN
        RAISE NOTICE '';
        RAISE NOTICE '======== TOTAL: % subastas, % con ganador, $ % recaudado ========',
            t_sub, t_gan, t_rec;
    END IF;

    CLOSE cur;
END;
$$ LANGUAGE plpgsql;
