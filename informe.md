# Informe — TP Especial: Sistema de Subastas Online

**Base de Datos I — 1er Cuatrimestre 2026 — PostgreSQL 18.4**

---

## 1. Roles de los integrantes

Todos los integrantes participaron en el desarrollo y las pruebas. Además, cada
uno tuvo asignado un rol de supervisión sobre un área del trabajo:

| Integrante                | Rol de supervisión                  | Secciones a cargo                                  |
| ------------------------- | ----------------------------------- | -------------------------------------------------- |
| _(Nombre y apellido)_     | Encargado del trigger               | Triggers `subasta_bi` y `oferta_bi` y casos de prueba |
| _(Nombre y apellido)_     | Encargado de las funciones          | `cerrar_subasta` y `reporte_subastas`              |
| _(Nombre y apellido)_     | Encargado del funcionamiento global | DDL, importación y verificación end-to-end         |
| _(Nombre y apellido)_     | Encargado del informe               | Redacción, ortografía y armado final               |

La tarea de **investigación** (sintaxis de PL/pgSQL, cursores, `COPY`, etc.) se
repartió de forma transversal entre los cuatro integrantes.

---

## 2. Investigación realizada

Para resolver el trabajo se investigaron los siguientes temas:

- **Triggers en PL/pgSQL.** Se usaron triggers `BEFORE INSERT ... FOR EACH ROW`.
  La elección de `BEFORE` (en lugar de `AFTER`) es clave: permite (a) modificar
  la fila con `NEW.nro_oferta := ...` antes de insertarla y (b) autopoblar la
  tabla `usuario` *antes* de que se verifiquen las claves foráneas
  `email_vendedor`/`email_usuario`, de modo que la FK siempre quede satisfecha.
  La variable especial `NEW` representa la fila que se está por insertar.
- **`%ROWTYPE`.** Se declararon variables como `v_sub subasta%ROWTYPE` para
  traer una fila completa de `subasta` con un único `SELECT * INTO`.
- **`RAISE EXCEPTION` vs `RAISE NOTICE`.** `RAISE EXCEPTION` aborta la
  transacción y deshace la operación (se usa en los rechazos del trigger y de
  `cerrar_subasta`); `RAISE NOTICE` solo emite un mensaje informativo sin
  abortar (se usa para la salida del reporte). En `psql` los `NOTICE` salen por
  consola; en pgAdmin aparecen en la pestaña **Messages**.
- **Cursores explícitos.** En `reporte_subastas` se declaró un cursor con
  `CURSOR FOR SELECT ...` y se recorrió con `OPEN` / `FETCH ... INTO` /
  `EXIT WHEN NOT FOUND` / `CLOSE`, tal como exige el enunciado (en lugar de
  `RETURN TABLE` o un `FOR ... IN SELECT`).
- **`now()` vs `CURRENT_DATE`.** Para validar si una subasta venció se usó
  `now()` (timestamp con fecha y hora), porque `fecha_cierre` es un `TIMESTAMP`
  con hora. El parámetro `p_desde` del reporte, en cambio, es `DATE`.
- **`COPY` / `\copy` y `ON CONFLICT`.** Se investigó la diferencia entre el
  `COPY` server-side y el `\copy` del cliente, y la alternativa idiomática
  `INSERT ... ON CONFLICT DO NOTHING` para el autopoblado (se optó por
  `IF NOT EXISTS` por ser más explícito y legible).
- **Desempate de la mayor oferta.** Ante montos iguales se toma la oferta con
  menor `nro_oferta` (`ORDER BY monto DESC, nro_oferta ASC`), es decir la
  primera en alcanzar ese máximo.

---

## 3. Dificultades encontradas y cómo se resolvieron

- **Orden de las validaciones del trigger.** El enunciado exige un orden exacto.
  Se respetó: (1) autopoblar usuario, (2) existencia de subasta + rango de
  fechas, (3) oferente ≠ vendedor, (4) no dos ofertas consecutivas del mismo
  usuario, (5) validación de monto, (6) asignación de `nro_oferta`.
- **FK contra `usuario` durante la importación.** Al principio la carga fallaba
  porque `usuario` estaba vacía. Se resolvió haciendo el autopoblado en triggers
  `BEFORE INSERT`, que insertan el usuario antes de validar la FK.
- **`nro_oferta` correlativo.** Como es entidad débil con PK compuesta
  `(id_subasta, nro_oferta)` y el CSV no trae `nro_oferta`, se calcula dentro
  del trigger como `MAX(nro_oferta) + 1` por subasta.
- **Idempotencia de `cerrar_subasta` sin ofertas.** Cuando una subasta vence sin
  ofertas, la función retorna sin modificar ni lanzar error, de modo que se
  puede invocar varias veces sin fallar.
- **Dependencia de la fecha del sistema.** Los ganadores dependen de `now()`.
  Para verificar contra los números del enunciado (31 subastas, 8 con ganador,
  $2.163.000) se cerraron las subastas vencidas a la fecha de referencia del
  ejemplo y se obtuvo exactamente esa salida.
- **Codificación UTF-8.** Los datos contienen tildes (Electrónica, Vehículos,
  óleo). Se importó con `ENCODING 'UTF8'` para evitar caracteres corruptos.

---

## 4. Proceso de importación de los datos

Los archivos CSV de la cátedra **no se modificaron**. La importación se realizó
con `\copy` desde `psql` (no requiere permisos de superusuario y lee el archivo
del cliente). El orden es **primero `subasta`, después `oferta`**, porque
`oferta` tiene una FK a `subasta` y el trigger de oferta necesita que la subasta
exista.

```sql
\copy subasta(id, descripcion, categoria, email_vendedor, fecha_inicio, fecha_cierre, precio_base, incremento_min) \
  FROM 'subasta.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\copy oferta(id_subasta, email_usuario, fecha_hora, monto) \
  FROM 'oferta.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
```

Detalles relevantes:

- En `subasta` se **listan las columnas** porque el CSV no trae
  `email_ganador` ni `monto_ganador` (quedan en NULL hasta el cierre).
- En `oferta` se **listan las columnas** porque el CSV no trae `nro_oferta`
  (lo asigna el trigger).
- Al ejecutar el `\copy` se disparan los triggers: se autopobla `usuario`, se
  validan las reglas de negocio y se numeran las ofertas.

Verificación de la carga:

```sql
SELECT COUNT(*) FROM subasta;  -- 31
SELECT COUNT(*) FROM oferta;   -- 139
SELECT COUNT(*) FROM usuario;  -- 25 (autopoblados)
```

Ninguna fila fue rechazada durante la importación, tal como anticipa el
enunciado.

---

## 5. Resultado de la verificación

- Los **6 casos** del trigger de ofertas se comportan como pide el enunciado:
  2 inserciones válidas (`nro_oferta` 1 y 2) y 4 rechazos con mensaje claro.
- `cerrar_subasta`: la subasta 150 asigna `victoria.reyes@mail.com` por
  $285.000; la 100 (abierta) y la 150 (ya cerrada) lanzan error; la 200
  (vencida sin ofertas) no hace nada y se puede reinvocar sin fallar.
- `reporte_subastas` reproduce exactamente la salida del enunciado:
  **31 subastas, 8 con ganador, $2.163.000 recaudado**, con los subtotales por
  categoría correctos. El filtro por `Electrónica` da 7/3/$1.136.000 y una fecha
  futura no muestra nada.
