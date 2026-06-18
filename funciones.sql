-- TP Especial - Base de Datos I (1C 2026)
-- Sistema de subastas online en PostgreSQL.
-- Se ejecuta de arriba hacia abajo: tablas, triggers y funciones.

-- 1. Tablas
-- Borramos primero por si se corre el script varias veces.
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
    email_ganador   VARCHAR(255)  REFERENCES usuario(email),   -- se completa al cerrar
    monto_ganador   NUMERIC(12,2),                              -- se completa al cerrar
    CHECK (fecha_cierre > fecha_inicio)
);

CREATE TABLE oferta (
    id_subasta    INTEGER       NOT NULL REFERENCES subasta(id),
    nro_oferta    INTEGER       NOT NULL,                 -- lo pone el trigger, no el CSV
    email_usuario VARCHAR(255)  NOT NULL REFERENCES usuario(email),
    fecha_hora    TIMESTAMP     NOT NULL,
    monto         NUMERIC(12,2) NOT NULL,
    PRIMARY KEY (id_subasta, nro_oferta)
);

-- 2. Trigger: al insertar una subasta, damos de alta al vendedor si todavia
-- no esta en usuario. Va BEFORE INSERT para que la FK no falle.
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

-- 3. Trigger: valida cada oferta antes de insertarla. Si algo no cumple,
-- lanza una excepcion y la insercion se cancela. Los pasos siguen el orden
-- del enunciado y estan numerados abajo.
CREATE OR REPLACE FUNCTION trg_oferta_validar()
RETURNS TRIGGER AS $$
DECLARE
    v_sub        subasta%ROWTYPE;
    v_max_monto  NUMERIC(12,2);
    v_max_nro    INTEGER;
    v_count      INTEGER;
    v_ult_email  VARCHAR(255);
BEGIN
    -- (1) Si el oferente no existe, lo damos de alta
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE email = NEW.email_usuario) THEN
        INSERT INTO usuario(email) VALUES (NEW.email_usuario);
    END IF;

    -- (2) La subasta tiene que existir
    SELECT * INTO v_sub FROM subasta WHERE id = NEW.id_subasta;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La subasta % no existe.', NEW.id_subasta;
    END IF;

    -- y la oferta tiene que caer entre fecha_inicio y fecha_cierre
    IF NEW.fecha_hora < v_sub.fecha_inicio OR NEW.fecha_hora > v_sub.fecha_cierre THEN
        RAISE EXCEPTION 'La subasta % no esta activa en % (periodo % a %).',
            NEW.id_subasta, NEW.fecha_hora, v_sub.fecha_inicio, v_sub.fecha_cierre;
    END IF;

    -- (3) El vendedor no puede ofertar en su propia subasta
    IF NEW.email_usuario = v_sub.email_vendedor THEN
        RAISE EXCEPTION 'El vendedor % no puede pujar en su propia subasta %.',
            NEW.email_usuario, NEW.id_subasta;
    END IF;

    -- Traemos el mayor monto, el ultimo nro_oferta y cuantas ofertas hay
    SELECT COALESCE(MAX(monto), 0), COALESCE(MAX(nro_oferta), 0), COUNT(*)
      INTO v_max_monto, v_max_nro, v_count
      FROM oferta WHERE id_subasta = NEW.id_subasta;

    -- (4) Un usuario no puede ofertar dos veces seguidas
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

    -- (5) La primera oferta cubre el precio base; el resto supera la mayor
    --     oferta por al menos el incremento minimo
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

    -- (6) Numeramos la oferta de forma correlativa
    NEW.nro_oferta := v_max_nro + 1;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER oferta_bi
BEFORE INSERT ON oferta
FOR EACH ROW
EXECUTE FUNCTION trg_oferta_validar();

-- 4. cerrar_subasta(p_id): cierra una subasta vencida y le asigna ganador.
-- Chequea que exista, que ya haya pasado la fecha de cierre y que no tenga
-- ganador. Gana la oferta mas alta; si hay empate, la de menor nro_oferta.
-- Si nadie oferto, no hace nada (no es error).
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

    -- Buscamos la oferta ganadora (mayor monto, y ante empate la mas temprana)
    SELECT email_usuario, monto INTO v_email, v_monto
      FROM oferta
     WHERE id_subasta = p_id
     ORDER BY monto DESC, nro_oferta ASC
     LIMIT 1;

    IF NOT FOUND THEN
        RETURN;  -- la subasta cerro sin ofertas
    END IF;

    UPDATE subasta
       SET email_ganador = v_email,
           monto_ganador = v_monto
     WHERE id = p_id;
END;
$$ LANGUAGE plpgsql;

-- 5. reporte_subastas(p_desde, p_categoria): imprime un reporte con RAISE NOTICE.
-- Recorre con un cursor las subastas que cierran a partir de p_desde (se puede
-- filtrar por categoria), agrupadas por categoria. Muestra cada subasta con su
-- ganador o la cantidad de ofertas, un subtotal por categoria y un total final.
-- Si no hay subastas, no imprime nada.
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
    -- subtotales de la categoria actual
    c_sub INTEGER; c_gan INTEGER; c_rec NUMERIC(14,2);
    -- totales generales
    t_sub INTEGER := 0; t_gan INTEGER := 0; t_rec NUMERIC(14,2) := 0;
BEGIN
    OPEN cur;
    LOOP
        FETCH cur INTO rec;
        EXIT WHEN NOT FOUND;

        -- Encabezado: lo imprimimos al ver la primera fila
        IF NOT v_hay THEN
            RAISE NOTICE '====== REPORTE DE SUBASTAS ======';
            IF p_categoria IS NOT NULL THEN
                RAISE NOTICE '   Categoría: %', p_categoria;
            END IF;
            RAISE NOTICE '   Desde: %', p_desde;
            v_hay := TRUE;
        END IF;

        -- Cuando cambia la categoria, cerramos el subtotal y arrancamos otra
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

        -- Contamos las ofertas de esta subasta
        SELECT COUNT(*) INTO v_ofertas FROM oferta WHERE id_subasta = rec.id;

        -- Imprimimos la subasta: con ganador o sin ganador
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

    -- Falta el subtotal de la ultima categoria (el loop ya no lo cierra)
    IF v_cat IS NOT NULL THEN
        RAISE NOTICE '   -- subtotal %: % subastas, % con ganador, $ % recaudado',
            v_cat, c_sub, c_gan, c_rec;
    END IF;

    -- Total general
    IF v_hay THEN
        RAISE NOTICE '';
        RAISE NOTICE '======== TOTAL: % subastas, % con ganador, $ % recaudado ========',
            t_sub, t_gan, t_rec;
    END IF;

    CLOSE cur;
END;
$$ LANGUAGE plpgsql;
