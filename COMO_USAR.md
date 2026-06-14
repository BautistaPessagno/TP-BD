# Cómo probar y usar el TP

Guía paso a paso para levantar la base, cargar los datos y ejecutar los
triggers y funciones. Hay dos caminos: **`psql`** (terminal) y **pgAdmin**
(interfaz gráfica). Al final se explica cómo ver las tablas en pgAdmin.

---

## 0. Requisitos

- PostgreSQL 18 instalado (ya disponible: `psql (PostgreSQL) 18.4 (Homebrew)`).
- Estar parado en la carpeta del proyecto (donde están `funciones.sql`,
  `subasta.csv` y `oferta.csv`).

Arrancar el servidor (si no está corriendo):

```bash
brew services start postgresql@18
pg_isready            # debe decir: accepting connections
```

---

## CAMINO A — Terminal (psql)

### 1. Crear la base

```bash
dropdb --if-exists tp_subastas    # por si querés empezar de cero
createdb tp_subastas
```

### 2. Crear tablas + triggers + funciones

```bash
psql tp_subastas -f funciones.sql
```

Esto crea las 3 tablas, los 2 triggers y las 2 funciones. Si lo corrés más de
una vez no hay problema: el script empieza con `DROP TABLE IF EXISTS`.

### 3. Importar los CSV (¡primero subasta, después oferta!)

```bash
psql tp_subastas
```

Y dentro de `psql`:

```sql
\copy subasta(id, descripcion, categoria, email_vendedor, fecha_inicio, fecha_cierre, precio_base, incremento_min) FROM 'subasta.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\copy oferta(id_subasta, email_usuario, fecha_hora, monto) FROM 'oferta.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
```

Verificar la carga:

```sql
SELECT COUNT(*) FROM subasta;   -- 31
SELECT COUNT(*) FROM oferta;    -- 139
SELECT COUNT(*) FROM usuario;   -- 25 (autopoblados por los triggers)
```

### 4. Probar el trigger de ofertas (los 6 casos)

> Estos INSERT ensucian la tabla. Hacelos dentro de `BEGIN; ... ROLLBACK;`
> para no contaminar los datos reales.

```sql
BEGIN;

-- (1) OK -> nro_oferta = 1
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (100, 'carla.perez@mail.com', '2026-06-10 14:00:00', 50000);

-- (2) OK -> nro_oferta = 2
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (100, 'hernan.diaz@mail.com', '2026-06-10 15:00:00', 55000);

SELECT id_subasta, nro_oferta, email_usuario, monto FROM oferta WHERE id_subasta = 100;

-- (3) RECHAZA: mismo usuario que la última oferta
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (100, 'hernan.diaz@mail.com', '2026-06-10 16:00:00', 60000);

-- (4) RECHAZA: oferente = vendedor
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (100, 'elena.garcia@mail.com', '2026-06-10 17:00:00', 65000);

-- (5) RECHAZA: monto insuficiente (requiere >= 60000)
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (100, 'lucas.acosta@mail.com', '2026-06-10 18:00:00', 57000);

-- (6) RECHAZA: subasta vencida
INSERT INTO oferta (id_subasta, email_usuario, fecha_hora, monto)
VALUES (150, 'lucas.acosta@mail.com', '2026-06-15 12:00:00', 300000);

ROLLBACK;   -- deshace todo lo del test
```

Cada rechazo aparece como `ERROR: ...` con un mensaje claro.

### 5. Probar `cerrar_subasta`

```sql
SELECT cerrar_subasta(150);   -- OK: asigna victoria.reyes@mail.com / 285000
SELECT id, email_ganador, monto_ganador FROM subasta WHERE id = 150;

SELECT cerrar_subasta(100);   -- ERROR: todavía abierta
SELECT cerrar_subasta(150);   -- ERROR: ya cerrada con ganador
SELECT cerrar_subasta(200);   -- vencida SIN ofertas: no hace nada, sin error
SELECT cerrar_subasta(200);   -- re-invocación: tampoco falla
```

### 6. Cerrar todas las vencidas y ver el reporte

Para que el reporte muestre ganadores, primero hay que cerrar las subastas
vencidas:

```sql
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT id FROM subasta WHERE fecha_cierre <= now() AND email_ganador IS NULL LOOP
        PERFORM cerrar_subasta(r.id);
    END LOOP;
END $$;
```

Y después:

```sql
SELECT reporte_subastas('2026-01-01'::DATE, null);          -- todas las categorías
SELECT reporte_subastas('2026-01-01'::DATE, 'Electrónica'); -- solo Electrónica
SELECT reporte_subastas('2030-01-01'::DATE, null);          -- no muestra nada
```

> **Importante:** el reporte sale por `RAISE NOTICE`, así que aparece como
> mensajes `NOTICE:` en la consola, **no** en la grilla de resultados.

Salir de `psql` con `\q`.

---

## CAMINO B — pgAdmin

### 1. Conectarse y crear la base

1. Abrí **pgAdmin**.
2. En el panel izquierdo expandí **Servers** → tu servidor (te pide la
   contraseña del usuario `postgres` la primera vez).
3. Click derecho en **Databases** → **Create** → **Database…** → nombre
   `tp_subastas` → **Save**.

### 2. Ejecutar `funciones.sql`

1. Click en la base `tp_subastas` para seleccionarla.
2. Menú **Tools** → **Query Tool** (o el ícono de rayo/“Query Tool”).
3. Abrí el archivo: ícono de carpeta **Open File** → elegí `funciones.sql`.
4. Ejecutá con **F5** (o el botón ▶ play).

### 3. Importar los CSV

pgAdmin no soporta `\copy`. Usá el importador gráfico:

1. Expandí `tp_subastas` → **Schemas** → **public** → **Tables**.
2. Click derecho en la tabla **subasta** → **Import/Export Data…**
3. Pestaña **General**:
   - **Import/Export:** Import
   - **Filename:** elegí `subasta.csv`
   - **Format:** csv · **Encoding:** UTF8
4. Pestaña **Options:** **Header** → **Yes** · **Delimiter** → `,`
5. Pestaña **Columns:** dejá **solo** las columnas del CSV
   (id, descripcion, categoria, email_vendedor, fecha_inicio, fecha_cierre,
   precio_base, incremento_min). **Sacá** `email_ganador` y `monto_ganador`.
6. **OK**.
7. Repetí con la tabla **oferta**, eligiendo `oferta.csv`. En **Columns** dejá
   solo: id_subasta, email_usuario, fecha_hora, monto (**sacá** `nro_oferta`).

> Hacé **subasta primero** y **oferta después** (la FK lo requiere).

### 4. Ejecutar funciones y ver el reporte

En el **Query Tool** escribí, por ejemplo:

```sql
SELECT cerrar_subasta(150);
SELECT reporte_subastas('2026-01-01'::DATE, null);
```

Ejecutá con **F5**. **La salida de `reporte_subastas` aparece en la pestaña
`Messages`** del Query Tool (porque usa `RAISE NOTICE`), no en `Data Output`.

---

## Cómo VER las tablas en pgAdmin

### Ver la estructura (columnas, claves, triggers)

1. Panel izquierdo: **Servers** → tu servidor → **Databases** → `tp_subastas`
   → **Schemas** → **public** → **Tables**.
2. Ahí ves `usuario`, `subasta` y `oferta`.
3. Expandí cualquier tabla para ver **Columns**, **Constraints**, **Triggers**,
   etc.

> Si no aparecen las tablas, click derecho en **Tables** → **Refresh**.

### Ver los datos (las filas)

- Click derecho en la tabla (ej. `subasta`) → **View/Edit Data** → **All Rows**.
- O escribí en el Query Tool:

```sql
SELECT * FROM subasta ORDER BY id;
SELECT * FROM oferta ORDER BY id_subasta, nro_oferta;
SELECT * FROM usuario ORDER BY email;
```

y ejecutá con **F5**. Las filas salen en la pestaña **Data Output**.

---

## Resultado esperado (datos de la cátedra)

- `subasta` = 31 filas, `oferta` = 139 filas, `usuario` = 25 filas.
- Tras cerrar las vencidas, el reporte total da:
  **31 subastas, 8 con ganador, $ 2163000.00 recaudado**.
