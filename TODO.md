# TODO — TP Especial BD I (1C 2026)

Checklist completo y detallado del Trabajo Práctico Especial: **sistema de subastas online** en PostgreSQL aplicando **PSM (funciones)** y **Triggers**.

- **Entrega:** jueves **18/06/2026 23:59** por Campus ITBA.
- **Grupo:** 4 alumnos (excepción: un grupo de 3).
- **Entregables:** `funciones.sql` (todo el código) + **informe ≤ 3 páginas** (roles, investigación, dificultades, proceso de importación).
- **Motor:** PostgreSQL. Local disponible: **PostgreSQL 18.4 (Homebrew)** → se puede correr y verificar con `psql` o pgAdmin.

> [!check] Verificación previa hecha
> La lógica de negocio se simuló contra `subasta.csv` y `oferta.csv` y reproduce **exactamente** las salidas del enunciado: **31 subastas, 8 con ganador, $2.163.000 recaudado**; ganadores #104 ximena.aguirre/237000, #108 diego.sanchez/610000, #109 diego.sanchez/241000, #150 victoria.reyes/285000. La fecha de sistema de referencia del ejemplo es **2026-06-11**.

---

## 0. Setup del entorno

**Dónde:** Terminal + pgAdmin (o solo `psql`).

- [ ] Tener los 2 CSV de la cátedra a mano (NO se pueden modificar): `subasta.csv`, `oferta.csv`.
- [ ] Crear la base de datos de trabajo.
  - **Terminal:**
    ```bash
    createdb tp_subastas
    psql tp_subastas
    ```
  - **pgAdmin:** click derecho en _Databases_ → _Create_ → _Database…_ → nombre `tp_subastas`.
- [ ] Crear el archivo **`funciones.sql`** (será el entregable). Todo el código de las secciones 1, 2, 3, 5 y 6 va acá, en orden.
- [ ] Repo/carpeta del grupo para versionar `funciones.sql` + informe.

> [!note] Cómo se ven los `RAISE NOTICE`
> En **psql** aparecen en la consola. En **pgAdmin** aparecen en la pestaña **Messages** del Query Tool (no en _Data Output_).

---

## 1. Crear las 3 tablas (DDL)

**Dónde:** `funciones.sql` → ejecutar en pgAdmin Query Tool o `psql`.

Reglas de modelado:

- `USUARIO`: un solo campo `email` (PK). **No se carga por archivo**, se autopobla por triggers.
- `SUBASTA`: 1 vendedor (FK a usuario). `email_ganador` y `monto_ganador` admiten **NULL** hasta procesar el cierre.
- `OFERTA`: **entidad débil** dependiente de la subasta → **PK compuesta `(id_subasta, nro_oferta)`** + FK a `subasta`.

- [ ] Escribir y ejecutar el DDL:

```sql
-- Limpieza para reruns (opcional, útil mientras desarrollás)
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
    PRIMARY KEY (id_subasta, nro_oferta)                 -- entidad débil
);
```

> [!warning] Por qué funciona el orden de los triggers con las FK
> Los triggers de autopoblado son **BEFORE INSERT**: insertan el usuario _antes_ de que se inserte la fila de `subasta`/`oferta`, así que la FK `email_vendedor`/`email_usuario` → `usuario` queda satisfecha. No hace falta cargar `usuario` a mano.

---

## 2. Trigger b — autopoblar vendedores (sobre `SUBASTA`)

**Dónde:** `funciones.sql`, después del DDL.

Objetivo: al insertar una subasta, si el `email_vendedor` no existe en `USUARIO`, insertarlo; si existe, no hacer nada.

- [ ] Implementar función + trigger:

```sql
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
```

> [!tip] Alternativa idiomática
> En vez del `IF NOT EXISTS`, se puede usar `INSERT ... ON CONFLICT (email) DO NOTHING;`. Ambas cumplen el requisito; elegí una y justificala en el informe.

---

## 3. Trigger c — validar e insertar ofertas (sobre `OFERTA`)

**Dónde:** `funciones.sql`. Es el punto más pesado. Las acciones van en **este orden exacto** (lo pide el enunciado):

1. Autopoblar `USUARIO` con `email_usuario` si no existe.
2. Validar que la **subasta exista** y que `fecha_hora` ∈ `[fecha_inicio, fecha_cierre]`.
3. Validar que el oferente **no sea el vendedor**.
4. Validar que el oferente **no haya hecho la última oferta** (no dos seguidas del mismo usuario).
5. Validar **monto**: 1ª oferta ≥ `precio_base`; siguiente ≥ `mayor_actual + incremento_min`.
6. Asignar `nro_oferta` = siguiente correlativo.

Cada rechazo → `RAISE EXCEPTION` con mensaje claro (deshace la operación).

- [ ] Implementar función + trigger:

```sql
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
        RAISE EXCEPTION 'La subasta % no está activa en % (periodo % a %).',
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
            RAISE EXCEPTION 'El usuario % ya realizó la última oferta de la subasta % (debe esperar a otro oferente).',
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
            RAISE EXCEPTION 'El monto (%) debe superar la mayor oferta (%) en al menos % (mínimo requerido: %).',
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
```

- [ ] **Probar los 6 casos del enunciado** (deben dar exactamente lo esperado) sobre una subasta de prueba (#100, vacía):

```sql
-- OK -> nro_oferta = 1
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (100, 'carla.perez@mail.com', '2026-06-10 14:00:00', 50000);
-- OK -> nro_oferta = 2
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (100, 'hernan.diaz@mail.com', '2026-06-10 15:00:00', 55000);

-- RECHAZAR (3) misma subasta, mismo usuario que la última oferta
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (100, 'hernan.diaz@mail.com', '2026-06-10 16:00:00', 60000);
-- RECHAZAR (4) oferente = vendedor (elena.garcia es la vendedora de #100)
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (100, 'elena.garcia@mail.com', '2026-06-10 17:00:00', 65000);
-- RECHAZAR (5) monto insuficiente (requiere >= 60000)
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (100, 'lucas.acosta@mail.com', '2026-06-10 18:00:00', 57000);
-- RECHAZAR (6) subasta vencida (fecha_hora > fecha_cierre)
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (150, 'lucas.acosta@mail.com', '2026-06-15 12:00:00', 300000);
```

> [!warning] Importante para el test
> Estos INSERT de prueba ensucian la tabla. Hacelos en una DB descartable **o** ejecutalos dentro de un `BEGIN; ... ROLLBACK;` para no contaminar los datos antes de la importación real.

---

## 4. Importar los datos con `COPY`

**Dónde:** `psql` (recomendado con `\copy`) o pgAdmin (Import/Export Data). **NO** modificar los CSV.

Claves:

- Importar **primero `subasta`, después `oferta`** (FK + el trigger necesita la subasta).
- En `subasta` el CSV **no trae** `email_ganador`/`monto_ganador` → hay que listar columnas.
- En `oferta` el CSV **no trae** `nro_oferta` → listar columnas; el trigger lo asigna.
- Encoding **UTF-8** (hay tildes: Electrónica, Vehículos).

- [ ] **Opción A — `psql` con `\copy`** (lee archivo del cliente, no necesita permisos de superusuario). Ajustá las rutas:

```sql
\copy subasta(id, descripcion, categoria, email_vendedor, fecha_inicio, fecha_cierre, precio_base, incremento_min) FROM 'subasta.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\copy oferta(id_subasta, email_usuario, fecha_hora, monto) FROM 'oferta.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
```

- [ ] **Opción B — `COPY` server-side** (lo que pide literal el enunciado; el archivo debe ser legible por el server y se corre como superusuario):

```sql
COPY subasta(id, descripcion, categoria, email_vendedor, fecha_inicio, fecha_cierre, precio_base, incremento_min)
FROM '/ruta/absoluta/subasta.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

COPY oferta(id_subasta, email_usuario, fecha_hora, monto)
FROM '/ruta/absoluta/oferta.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
```

- [ ] **Opción C — pgAdmin:** click derecho en la tabla → _Import/Export Data…_ → pestaña _Columns_: dejar solo las columnas del CSV (sacar `nro_oferta`, `email_ganador`, `monto_ganador`) → _Header: Yes_, _Delimiter: ,_, _Encoding: UTF8_.

- [ ] **Verificar la carga** (al importar se disparan los triggers: autopoblan `usuario`, validan y numeran ofertas):

```sql
SELECT COUNT(*) FROM subasta;  -- 31
SELECT COUNT(*) FROM oferta;   -- 139
SELECT COUNT(*) FROM usuario;  -- usuarios únicos autopoblados
-- nro_oferta correlativo por subasta:
SELECT id_subasta, MIN(nro_oferta), MAX(nro_oferta), COUNT(*) FROM oferta GROUP BY id_subasta ORDER BY id_subasta;
```

> [!note] Documentar para el informe
> El proceso de importación (comando usado, rutas, encoding, problemas) **debe** ir en el informe.

---

## 5. Función `cerrar_subasta(p_id)` (PSM)

**Dónde:** `funciones.sql`.

Lógica:

- Validar que la subasta **exista** (si no → excepción).
- Validar que el **plazo venció** (`fecha_cierre <= now()`; si sigue activa → excepción).
- Validar que **no tenga ganador** ya asignado (si ya cerró con ganador → excepción).
- Si pasa todo: tomar la **mayor oferta** y setear `email_ganador` / `monto_ganador`.
- Si **cerró sin ofertas**: terminar normal **sin modificar y sin error** (idempotente: re-invocar no debe fallar).

- [ ] Implementar:

```sql
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
        RAISE EXCEPTION 'La subasta % todavía está abierta (cierra %).', p_id, v_sub.fecha_cierre;
    END IF;

    IF v_sub.email_ganador IS NOT NULL THEN
        RAISE EXCEPTION 'La subasta % ya fue cerrada con ganador %.', p_id, v_sub.email_ganador;
    END IF;

    -- Mayor oferta (desempate por nro_oferta más bajo = la más temprana en alcanzar el máximo)
    SELECT email_usuario, monto INTO v_email, v_monto
      FROM oferta
     WHERE id_subasta = p_id
     ORDER BY monto DESC, nro_oferta ASC
     LIMIT 1;

    IF NOT FOUND THEN
        RETURN;  -- cerró sin ofertas: no se modifica nada, sin error
    END IF;

    UPDATE subasta
       SET email_ganador = v_email,
           monto_ganador = v_monto
     WHERE id = p_id;
END;
$$ LANGUAGE plpgsql;
```

- [ ] **Probar** los casos del enunciado:

```sql
SELECT cerrar_subasta(150);   -- asigna ganador victoria.reyes@mail.com / 285000
SELECT cerrar_subasta(100);   -- ERROR: todavía abierta
SELECT cerrar_subasta(150);   -- ERROR: ya cerrada con ganador
SELECT cerrar_subasta(200);   -- vencida SIN ofertas: no hace nada, sin error
SELECT cerrar_subasta(200);   -- re-invocación: tampoco falla
```

> [!tip] Cerrar todas las vencidas de una (para generar el reporte)
> No es obligatorio, pero ayuda a testear:
>
> ```sql
> DO $$
> DECLARE r RECORD;
> BEGIN
>     FOR r IN SELECT id FROM subasta WHERE fecha_cierre <= now() AND email_ganador IS NULL LOOP
>         PERFORM cerrar_subasta(r.id);
>     END LOOP;
> END $$;
> ```

---

## 6. Función `reporte_subastas(p_desde, p_categoria)` (PSM)

**Dónde:** `funciones.sql`.

Requisitos:

- Firma: `reporte_subastas(p_desde DATE, p_categoria VARCHAR DEFAULT NULL)`.
- Filtra subastas con `fecha_cierre >= p_desde`, opcionalmente por categoría.
- **Cursor explícito** para recorrer; salida por **`RAISE NOTICE`**.
- Encabezado (con categoría si se filtró + fecha desde), un bloque por categoría (orden **alfabético**), un renglón por subasta (orden por `id`), **subtotal por categoría** y **total general**.
- Renglón: ganador si existe, o cantidad de ofertas si no tiene ganador.
- Si **no hay** subastas que cumplan → **no mostrar nada** (ni el encabezado).

- [ ] Implementar:

```sql
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
    -- contadores por categoría
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

        -- Cambio de categoría: cerrar subtotal anterior y abrir bloque nuevo
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

        -- Renglón de la subasta
        IF rec.email_ganador IS NOT NULL THEN
            RAISE NOTICE '   [#%] % - base $ % -> ganador % por $ %',
                rec.id, rec.descripcion, rec.precio_base, rec.email_ganador, rec.monto_ganador;
            c_gan := c_gan + 1;  t_gan := t_gan + 1;
            c_rec := c_rec + rec.monto_ganador;  t_rec := t_rec + rec.monto_ganador;
        ELSE
            SELECT COUNT(*) INTO v_ofertas FROM oferta WHERE id_subasta = rec.id;
            RAISE NOTICE '   [#%] % - base $ % -> sin ganador asignado (% ofertas)',
                rec.id, rec.descripcion, rec.precio_base, v_ofertas;
        END IF;
        c_sub := c_sub + 1;  t_sub := t_sub + 1;
    END LOOP;

    -- Subtotal de la última categoría
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
```

- [ ] **Probar** y comparar con el enunciado (después de cerrar las vencidas):

```sql
SELECT reporte_subastas('2026-01-01'::DATE, null);          -- 31 subastas, 8 con ganador, $2.163.000
SELECT reporte_subastas('2026-01-01'::DATE, 'Electrónica'); -- 7 subastas, 3 con ganador, $1.136.000
SELECT reporte_subastas('2030-01-01'::DATE, null);          -- no muestra NADA (ni encabezado)
```

> [!check] Resultados esperados (verificados contra los CSV)
> Total general: **31 subastas, 8 con ganador, $2.163.000**.
> Subtotales: Arte 7/1/237000 · Coleccionables 6/1/156000 · Electrónica 7/3/1136000 · Libros 6/1/291000 · Vehículos 5/2/343000.
> Si tus números no dan, revisá: (a) cerraste todas las vencidas, (b) la fecha de sistema de tu máquina, (c) el desempate de la mayor oferta.

---

## 7. Verificación final (correr todo de cero)

**Dónde:** `psql tp_subastas` o pgAdmin.

- [ ] DB limpia → ejecutar `funciones.sql` completo (tablas + triggers + funciones) sin errores.
- [ ] Importar ambos CSV con `COPY`/`\copy` (ninguna fila debe rechazarse).
- [ ] Correr los 6 casos del trigger c → 2 OK + 4 rechazos con mensaje claro.
- [ ] Correr los casos de `cerrar_subasta` (150 OK, 100 abierta, 150 ya cerrada, 200 sin ofertas ×2).
- [ ] Cerrar todas las vencidas y correr los 3 `reporte_subastas` → comparar números con la sección 6.
- [ ] Probar con la fecha de sistema real: los ganadores dependen de `now()`.

---

## 8. Entregables

- [ ] **`funciones.sql`** — un único script con: DDL (tablas) + 2 triggers + 2 funciones, en orden ejecutable de cero.
- [ ] **Informe ≤ 3 páginas**, sin faltas de ortografía, con:
  - [ ] **Rol de cada integrante** (mínimo: encargado del informe, de las funciones, del trigger, del funcionamiento global, de investigación). Todos participan; cada uno supervisa un área.
  - [ ] **Todo lo investigado** (sintaxis de triggers PL/pgSQL, cursores, `RAISE`, `COPY`, `%ROWTYPE`, `now()` vs `CURRENT_DATE`, etc.).
  - [ ] **Dificultades** encontradas y cómo se resolvieron.
  - [ ] **Proceso de importación** detallado (comando, rutas, encoding, orden subasta→oferta).
- [ ] Subir todo a **Campus ITBA** antes del **18/06 23:59**.

---

## 9. Reparto de roles sugerido (grupo de 4)

| Rol                                | Responsable de                            | Secciones   |
| ---------------------------------- | ----------------------------------------- | ----------- |
| Encargado del trigger              | Triggers b y c, casos de prueba           | 2, 3        |
| Encargado de funciones             | `cerrar_subasta`, `reporte_subastas`      | 5, 6        |
| Encargado de funcionamiento global | DDL, importación, verificación end-to-end | 1, 4, 7     |
| Encargado del informe              | Redacción, ortografía, armado final       | 8           |
| (Investigación: rota entre los 4)  | Sintaxis PL/pgSQL, cursores, COPY         | transversal |

---

## Puntos críticos (donde se pierde nota)

- [ ] El **orden de validaciones del trigger c** debe coincidir con el enunciado.
- [ ] `OFERTA` es **entidad débil** → PK compuesta `(id_subasta, nro_oferta)`, no un id propio.
- [ ] `nro_oferta` lo asigna el **trigger**, nunca lo provee el usuario ni el CSV.
- [ ] `cerrar_subasta` debe ser **idempotente** sobre subastas sin ofertas (no fallar al re-invocar).
- [ ] `reporte_subastas` con **cursor explícito** y salida por `RAISE NOTICE` (no `RETURN TABLE`).
- [ ] Consultas **genéricas**: los docentes prueban con otros datasets. Nada hardcodeado a estos CSV.
- [ ] Mensajes de error **claros** en cada `RAISE EXCEPTION`.
