-- ==============================================================================
-- SCRIPT 01 | STREAMING RETENTION INSIGHTS
-- DDL MAESTRO: ESQUEMA + DATOS SIMULADOS
-- Versión: 6.0 | Arquitectura de Datos Principal | SQL Server 2019+
-- Cambios v6.0: Geo-Pricing (Paises_Monedas + Planes_Precios_Localizados),
--               columnas calculadas Streamshare en Pagos, modelo de precios
--               competitivos 2026, eliminación de core.Monedas como tabla
--               independiente (absorbida por Paises_Monedas), UTC absoluto
-- ==============================================================================

CREATE DATABASE Streaming_Retention_Insights_v2;
GO
USE Streaming_Retention_Insights_v2;
GO

-- ==============================================================================
-- BLOQUE 1: ESQUEMAS
-- ==============================================================================
CREATE SCHEMA core      AUTHORIZATION dbo;
GO
CREATE SCHEMA analytics AUTHORIZATION dbo;
GO

-- ==============================================================================
-- BLOQUE 2: TALLY TABLE — generador secuencial limpio (0–9,999)
-- Cross join de 4 × 10 VALUES → 10,000 filas, operación de metadatos pura.
-- Reemplaza sys.all_columns en todos los bloques de simulación.
-- ==============================================================================
CREATE TABLE #Tally (n INT NOT NULL PRIMARY KEY CLUSTERED);

INSERT INTO #Tally (n)
SELECT TOP 10000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
FROM       (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) a(x)
CROSS JOIN (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) b(x)
CROSS JOIN (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) c(x)
CROSS JOIN (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) d(x);
GO

-- ==============================================================================
-- BLOQUE 3: DDL — CATÁLOGOS (core.*)
-- ==============================================================================

-- ----------------------------------------------------------------------------
-- core.Metodos_Pago
-- Catálogo normalizado de métodos de cobro. activo BIT = soft delete.
-- ----------------------------------------------------------------------------
CREATE TABLE core.Metodos_Pago (
    id_metodo     TINYINT     NOT NULL IDENTITY(1,1),
    nombre_metodo VARCHAR(30) NOT NULL,
    activo        BIT         NOT NULL DEFAULT 1,
    CONSTRAINT PK_Metodos_Pago        PRIMARY KEY CLUSTERED (id_metodo),
    CONSTRAINT UQ_Metodos_Pago_nombre UNIQUE (nombre_metodo)
);

-- ----------------------------------------------------------------------------
-- core.Paises_Monedas
-- Catálogo único de mercados: combina país + moneda + código ISO.
-- Elimina la tabla core.Monedas independiente de v5.0 — la moneda es
-- inseparable del país en el modelo de geo-pricing.
-- CHAR(2) para codigo_pais: ISO 3166-1 alpha-2.
-- CHAR(3) para codigo_moneda: ISO 4217.
-- ----------------------------------------------------------------------------
CREATE TABLE core.Paises_Monedas (
    id_pais        TINYINT     NOT NULL IDENTITY(1,1),
    nombre_pais    VARCHAR(50) NOT NULL,
    codigo_pais    CHAR(2)     NOT NULL,   -- ISO 3166-1 alpha-2
    codigo_moneda  CHAR(3)     NOT NULL,   -- ISO 4217
    CONSTRAINT PK_Paises_Monedas          PRIMARY KEY CLUSTERED (id_pais),
    CONSTRAINT UQ_Paises_Monedas_codigo   UNIQUE (codigo_pais)
);

-- ----------------------------------------------------------------------------
-- core.Planes
-- Sin precio en esta tabla. Precio por mercado vive en Planes_Precios_Localizados.
-- ----------------------------------------------------------------------------
CREATE TABLE core.Planes (
    id_plan              TINYINT      NOT NULL IDENTITY(1,1),
    nombre_plan          NVARCHAR(60) NOT NULL,
    duracion_dias_prueba TINYINT      NOT NULL DEFAULT 0,
    max_sesiones_simult  TINYINT      NOT NULL DEFAULT 1
        CONSTRAINT CHK_Planes_sesiones CHECK (max_sesiones_simult BETWEEN 1 AND 6),
    CONSTRAINT PK_Planes PRIMARY KEY CLUSTERED (id_plan)
);

-- ----------------------------------------------------------------------------
-- core.Planes_Precios_Localizados
-- Tabla intermedia: precio real por plan × mercado, en moneda local.
-- PK compuesta (id_plan, id_pais): garantiza un precio único por combinación.
-- precio_local DECIMAL(10,2): cubre rangos desde 9.99 USD hasta 1,800 ARS.
-- ----------------------------------------------------------------------------
CREATE TABLE core.Planes_Precios_Localizados (
    id_plan      TINYINT      NOT NULL,
    id_pais      TINYINT      NOT NULL,
    precio_local DECIMAL(10,2) NOT NULL
        CONSTRAINT CHK_PPL_precio CHECK (precio_local > 0),
    CONSTRAINT PK_Planes_Precios    PRIMARY KEY CLUSTERED (id_plan, id_pais),
    CONSTRAINT FK_PPL_Plan          FOREIGN KEY (id_plan)
        REFERENCES core.Planes(id_plan),
    CONSTRAINT FK_PPL_Pais          FOREIGN KEY (id_pais)
        REFERENCES core.Paises_Monedas(id_pais)
);

-- ----------------------------------------------------------------------------
-- core.Clientes
-- id_pais FK → core.Paises_Monedas: vincula cliente a su mercado de origen.
-- Reemplaza pais_codigo/pais_nombre sueltos de v5.0 por FK normalizada.
-- VARCHAR(254) para email: límite RFC 5321.
-- TINYINT para edad: 13–99, ahorra 3 bytes × 1M filas vs INT.
-- ----------------------------------------------------------------------------
CREATE TABLE core.Clientes (
    id_cliente     INT          NOT NULL IDENTITY(1,1),
    email          VARCHAR(254) NOT NULL,
    fecha_registro DATE         NOT NULL,
    id_pais        TINYINT      NOT NULL,
    edad           TINYINT      NOT NULL
        CONSTRAINT CHK_Clientes_edad CHECK (edad BETWEEN 13 AND 99),
    CONSTRAINT PK_Clientes       PRIMARY KEY CLUSTERED (id_cliente),
    CONSTRAINT UQ_Clientes_email UNIQUE (email),
    CONSTRAINT FK_Clientes_Pais  FOREIGN KEY (id_pais)
        REFERENCES core.Paises_Monedas(id_pais)
);

-- Covering index para filtros de cohorte por mercado
CREATE NONCLUSTERED INDEX IX_Clientes_Pais_FechaReg
    ON core.Clientes (id_pais, fecha_registro)
    INCLUDE (id_cliente, edad);

-- ----------------------------------------------------------------------------
-- core.Suscripciones
-- fecha_fin NULL = suscripción vigente (convención documentada en comentario).
-- CHK_Susc_Fechas: fecha_fin siempre posterior a fecha_inicio si no es NULL.
-- ----------------------------------------------------------------------------
CREATE TABLE core.Suscripciones (
    id_suscripcion INT         NOT NULL IDENTITY(1,1),
    id_cliente     INT         NOT NULL,
    id_plan        TINYINT     NOT NULL,
    fecha_inicio   DATE        NOT NULL,
    fecha_fin      DATE        NULL,         -- NULL = suscripción vigente
    estado         VARCHAR(12) NOT NULL DEFAULT 'activa'
        CONSTRAINT CHK_Susc_estado CHECK (estado IN ('activa','cancelada','en_prueba')),
    CONSTRAINT PK_Suscripciones     PRIMARY KEY CLUSTERED (id_suscripcion),
    CONSTRAINT FK_Susc_Cliente      FOREIGN KEY (id_cliente)
        REFERENCES core.Clientes(id_cliente),
    CONSTRAINT FK_Susc_Plan         FOREIGN KEY (id_plan)
        REFERENCES core.Planes(id_plan),
    CONSTRAINT CHK_Susc_Fechas
        CHECK (fecha_fin IS NULL OR fecha_fin > fecha_inicio)
);

CREATE NONCLUSTERED INDEX IX_Susc_Cliente_FechaInicio
    ON core.Suscripciones (id_cliente, fecha_inicio)
    INCLUDE (id_plan, fecha_fin, estado);      -- covering: cohortes y LTV

CREATE NONCLUSTERED INDEX IX_Susc_Estado_FechaFin
    ON core.Suscripciones (estado, fecha_fin)
    INCLUDE (id_cliente, id_plan);             -- covering: clientes en riesgo

-- ----------------------------------------------------------------------------
-- core.Pagos
-- monto_bruto: importe cobrado en moneda local del cliente.
-- retencion_regalias / margen_operativo: columnas calculadas determinísticas
--   (modelo Streamshare estándar de la industria musical: 70/30).
--   PERSISTED no aplicado — son divisiones simples, más barato calcular on-read
--   que almacenar. Si las queries de royalties son frecuentes, se puede agregar
--   PERSISTED y un índice sobre retencion_regalias.
-- codigo_moneda: desnormalización controlada desde Paises_Monedas para
--   evitar un JOIN extra en cada query financiera.
-- id_metodo FK → core.Metodos_Pago: normalizado.
-- ----------------------------------------------------------------------------
CREATE TABLE core.Pagos (
    id_pago             BIGINT        NOT NULL IDENTITY(1,1),
    id_suscripcion      INT           NOT NULL,
    id_metodo           TINYINT       NOT NULL,
    codigo_moneda       CHAR(3)       NOT NULL,
    monto_bruto         DECIMAL(10,2) NOT NULL
        CONSTRAINT CHK_Pagos_monto CHECK (monto_bruto >= 0),
    -- Columnas calculadas determinísticas (modelo Streamshare 70/30)
    retencion_regalias  AS CAST(monto_bruto * 0.70 AS DECIMAL(10,2)),
    margen_operativo    AS CAST(monto_bruto * 0.30 AS DECIMAL(10,2)),
    fecha_pago          DATE          NOT NULL,
    estado_pago         VARCHAR(12)   NOT NULL DEFAULT 'exitoso'
        CONSTRAINT CHK_Pagos_estado
            CHECK (estado_pago IN ('exitoso','fallido','reembolsado')),
    CONSTRAINT PK_Pagos             PRIMARY KEY CLUSTERED (id_pago),
    CONSTRAINT FK_Pagos_Suscripcion FOREIGN KEY (id_suscripcion)
        REFERENCES core.Suscripciones(id_suscripcion),
    CONSTRAINT FK_Pagos_Metodo      FOREIGN KEY (id_metodo)
        REFERENCES core.Metodos_Pago(id_metodo)
    -- codigo_moneda sin FK a Paises_Monedas: es una desnormalización controlada
    -- (CHAR(3) copiado al insertar). Un CHECK constraint bastaría si se quiere
    -- validación sin el costo de FK lookup en inserts masivos.
);

-- MRR, churn de ingresos y análisis de royalties
CREATE NONCLUSTERED INDEX IX_Pagos_Susc_FechaPago
    ON core.Pagos (id_suscripcion, fecha_pago)
    INCLUDE (monto_bruto, estado_pago, codigo_moneda, id_metodo);

-- Detección de pagos fallidos (módulo de clientes en riesgo)
CREATE NONCLUSTERED INDEX IX_Pagos_Estado_FechaPago
    ON core.Pagos (estado_pago, fecha_pago)
    INCLUDE (id_suscripcion, monto_bruto, codigo_moneda);

-- ----------------------------------------------------------------------------
-- core.Sesiones
-- DATETIME2(0): UTC estricto, precisión de segundos.
-- FK explícita a core.Suscripciones (corregida desde v3.0).
-- Índice filtrado WHERE activa = 1: cero overhead para sesiones cerradas.
-- ----------------------------------------------------------------------------
CREATE TABLE core.Sesiones (
    id_sesion           BIGINT        NOT NULL IDENTITY(1,1),
    id_cliente          INT           NOT NULL,
    id_suscripcion      INT           NOT NULL,
    fecha_inicio_sesion DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    fecha_fin_sesion    DATETIME2(0)  NULL,
    ip_address          VARCHAR(45)   NULL,    -- IPv4 e IPv6 cubiertos
    dispositivo         NVARCHAR(100) NULL,
    activa              BIT           NOT NULL DEFAULT 1,
    CONSTRAINT PK_Sesiones              PRIMARY KEY CLUSTERED (id_sesion),
    CONSTRAINT FK_Sesiones_Cliente      FOREIGN KEY (id_cliente)
        REFERENCES core.Clientes(id_cliente),
    CONSTRAINT FK_Sesiones_Suscripcion  FOREIGN KEY (id_suscripcion)
        REFERENCES core.Suscripciones(id_suscripcion)
);

CREATE NONCLUSTERED INDEX IX_Sesiones_Activas
    ON core.Sesiones (id_cliente, fecha_inicio_sesion)
    WHERE activa = 1;

-- ==============================================================================
-- BLOQUE 4: DDL — analytics.Actividad_Usuario
--
-- PK CLUSTERED en id_actividad (BIGINT IDENTITY secuencial):
--   Las cargas batch nocturnas insertan fechas PASADAS. Con un clustered en
--   (id_cliente, fecha_actividad) cada batch inyectaría páginas en posiciones
--   intermedias del B-tree → page splits → fragmentación severa del buffer pool.
--   Con PK secuencial, cada INSERT escribe al final de la estructura: append-only,
--   sin splits, saludable indefinidamente bajo cualquier volumen de carga.
--
-- IX_AU_Cliente_Fecha (NONCLUSTERED, covering):
--   Cubre exactamente el patrón de lectura analítica:
--   WHERE id_cliente = X AND fecha_actividad BETWEEN Y AND Z
--   con INCLUDE de las columnas métricas → cero key lookups al clustered.
--
-- UQ_AU_Cliente_Dia: previene duplicados en reejecutciones ETL nocturnas.
-- ==============================================================================
CREATE TABLE analytics.Actividad_Usuario (
    id_actividad           BIGINT   NOT NULL IDENTITY(1,1),
    id_cliente             INT      NOT NULL,
    fecha_actividad        DATE     NOT NULL,
    minutos_escuchados     SMALLINT NOT NULL DEFAULT 0
        CONSTRAINT CHK_AU_minutos   CHECK (minutos_escuchados   >= 0),
    canciones_reproducidas SMALLINT NOT NULL DEFAULT 0
        CONSTRAINT CHK_AU_canciones CHECK (canciones_reproducidas >= 0),
    CONSTRAINT PK_Actividad_Usuario PRIMARY KEY CLUSTERED (id_actividad),
    CONSTRAINT UQ_AU_Cliente_Dia    UNIQUE NONCLUSTERED (id_cliente, fecha_actividad),
    CONSTRAINT FK_AU_Cliente        FOREIGN KEY (id_cliente)
        REFERENCES core.Clientes(id_cliente)
);

CREATE NONCLUSTERED INDEX IX_AU_Cliente_Fecha
    ON analytics.Actividad_Usuario (id_cliente, fecha_actividad)
    INCLUDE (minutos_escuchados, canciones_reproducidas);
GO

-- ==============================================================================
-- BLOQUE 5: DATOS MAESTROS
-- ==============================================================================
SET NOCOUNT ON;

INSERT INTO core.Metodos_Pago (nombre_metodo, activo) VALUES
    ('Tarjeta',       1),
    ('PayPal',        1),
    ('Yape',          1),
    ('Plin',          1),
    ('Transferencia', 1);

-- Mercados clave del proyecto (id_pais asignado por IDENTITY: 1=US,2=ES,3=MX,4=PE,5=CO,6=AR)
INSERT INTO core.Paises_Monedas (nombre_pais, codigo_pais, codigo_moneda) VALUES
    ('Estados Unidos', 'US', 'USD'),   -- id_pais = 1
    ('España',         'ES', 'EUR'),   -- id_pais = 2
    ('México',         'MX', 'MXN'),   -- id_pais = 3
    ('Perú',           'PE', 'PEN'),   -- id_pais = 4
    ('Colombia',       'CO', 'COP'),   -- id_pais = 5
    ('Argentina',      'AR', 'ARS');   -- id_pais = 6

INSERT INTO core.Planes (nombre_plan, duracion_dias_prueba, max_sesiones_simult) VALUES
    (N'Premium Estudiante',  0, 1),   -- id_plan = 1
    (N'Premium Individual',  0, 1),   -- id_plan = 2
    (N'Premium Duo',         0, 2),   -- id_plan = 3
    (N'Premium Familiar',    0, 4),   -- id_plan = 4
    (N'Premium Anual',       0, 1);   -- id_plan = 5

-- Precios localizados competitivos 2026 por plan × mercado
-- Fuente de referencia: precios públicos Spotify/Apple Music Q1-2026 por región
-- Formato: (id_plan, id_pais, precio_local)
INSERT INTO core.Planes_Precios_Localizados (id_plan, id_pais, precio_local) VALUES
-- Plan 1: Estudiante
    (1, 1,  5.99),      -- USD  — EE. UU.
    (1, 2,  4.99),      -- EUR  — España
    (1, 3, 59.00),      -- MXN  — México
    (1, 4,  8.90),      -- PEN  — Perú
    (1, 5,  6400.00),   -- COP  — Colombia
    (1, 6,  799.00),    -- ARS  — Argentina
-- Plan 2: Individual
    (2, 1, 10.99),      -- USD
    (2, 2,  9.99),      -- EUR
    (2, 3, 119.00),     -- MXN
    (2, 4, 16.90),      -- PEN
    (2, 5, 12900.00),   -- COP
    (2, 6, 1800.00),    -- ARS
-- Plan 3: Dúo
    (3, 1, 14.99),      -- USD
    (3, 2, 12.99),      -- EUR
    (3, 3, 159.00),     -- MXN
    (3, 4, 24.90),      -- PEN
    (3, 5, 17900.00),   -- COP
    (3, 6, 2500.00),    -- ARS
-- Plan 4: Familiar
    (4, 1, 16.99),      -- USD
    (4, 2, 14.99),      -- EUR
    (4, 3, 189.00),     -- MXN
    (4, 4, 29.90),      -- PEN
    (4, 5, 21900.00),   -- COP
    (4, 6, 3200.00),    -- ARS
-- Plan 5: Anual (precio único al contratar, equivale a ~10 meses)
    (5, 1,  99.99),     -- USD
    (5, 2,  89.99),     -- EUR
    (5, 3, 999.00),     -- MXN
    (5, 4, 149.00),     -- PEN
    (5, 5, 99900.00),   -- COP
    (5, 6, 14900.00);   -- ARS
GO

-- ==============================================================================
-- BLOQUE 6: SIMULACIÓN DE CLIENTES (1,000 registros) — UTC absoluto
-- Distribución por mercado: 50% Perú (id_pais=4), resto repartido entre los
-- 5 mercados restantes en proporción al tamaño de mercado simulado.
-- id_pais referencia core.Paises_Monedas directamente (FK normalizada).
-- ==============================================================================
DECLARE @hoy DATE = CAST(SYSUTCDATETIME() AS DATE);

WITH Numeros AS (
    SELECT TOP 1000 n FROM #Tally WHERE n BETWEEN 1 AND 1000
)
INSERT INTO core.Clientes (email, fecha_registro, id_pais, edad)
SELECT
    'usuario' + CAST(n AS VARCHAR(10)) + '@streamify.pe'              AS email,
    CAST(DATEADD(day, -(ABS(CHECKSUM(NEWID())) % 730), @hoy) AS DATE) AS fecha_registro,
    CASE
        WHEN n % 2 = 0 THEN 4                    -- 50% Perú
        ELSE CASE (n % 10)
            WHEN 0 THEN 1                         -- EE. UU.
            WHEN 1 THEN 2                         -- España
            WHEN 2 THEN 3                         -- México
            WHEN 3 THEN 5                         -- Colombia
            WHEN 4 THEN 6                         -- Argentina
            ELSE        4                         -- resto → Perú (refuerza mercado core)
        END
    END                                                                AS id_pais,
    CAST(13 + ABS(CHECKSUM(NEWID())) % 47 AS TINYINT)                 AS edad
FROM Numeros;
GO

-- ==============================================================================
-- BLOQUE 7: SIMULACIÓN DE SUSCRIPCIONES (CTE Recursiva — UTC absoluto)
-- Sin cambios lógicos respecto a v5.0 salvo el contexto de esquema.
-- ==============================================================================
DECLARE @hoy DATE = CAST(SYSUTCDATETIME() AS DATE);

WITH ClienteSuscCount AS (
    SELECT id_cliente, edad, ABS(CHECKSUM(NEWID())) % 3 + 1 AS total_susc
    FROM core.Clientes
),
SuscripcionesBase AS (
    SELECT
        id_cliente, edad, total_susc, 1 AS idx,
        CAST(DATEADD(day, -(ABS(CHECKSUM(NEWID())) % 600), @hoy) AS DATE) AS fecha_inicio
    FROM ClienteSuscCount
),
GeneradorCronologico AS (
    SELECT
        id_cliente, edad, total_susc, idx, fecha_inicio,
        CAST(DATEADD(month,
            2 + ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 10,
            fecha_inicio) AS DATE) AS fecha_fin
    FROM SuscripcionesBase

    UNION ALL

    SELECT
        g.id_cliente, g.edad, g.total_susc, g.idx + 1,
        CAST(DATEADD(day, 1, g.fecha_fin) AS DATE),
        CAST(DATEADD(month,
            2 + ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 10,
            DATEADD(day, 1, g.fecha_fin)) AS DATE)
    FROM GeneradorCronologico g
    WHERE g.idx < g.total_susc
)
INSERT INTO core.Suscripciones (id_cliente, id_plan, fecha_inicio, fecha_fin, estado)
SELECT
    id_cliente,
    CAST(CASE
        WHEN edad BETWEEN 13 AND 25 AND ABS(CHECKSUM(NEWID())) % 100 < 40 THEN 1
        WHEN edad BETWEEN 20 AND 40 AND ABS(CHECKSUM(NEWID())) % 100 < 30 THEN 3
        WHEN edad BETWEEN 25 AND 50 AND ABS(CHECKSUM(NEWID())) % 100 < 25 THEN 4
        WHEN ABS(CHECKSUM(NEWID())) % 100 < 5                              THEN 5
        ELSE 2
    END AS TINYINT)                                                         AS id_plan,
    fecha_inicio,
    CASE
        WHEN idx = total_susc AND fecha_inicio <= @hoy AND fecha_fin > @hoy
        THEN NULL
        ELSE fecha_fin
    END                                                                     AS fecha_fin,
    CASE
        WHEN idx = total_susc AND fecha_inicio <= @hoy AND fecha_fin > @hoy
        THEN 'activa'
        ELSE 'cancelada'
    END                                                                     AS estado
FROM GeneradorCronologico
WHERE fecha_inicio <= @hoy
OPTION (MAXRECURSION 5000);
GO

-- ==============================================================================
-- BLOQUE 8: SIMULACIÓN DE PAGOS — Geo-Pricing + Streamshare + UTC
--
-- FLUJO:
-- 1. #ClientePrecio materializa el precio local exacto de cada suscripción
--    vía JOIN Clientes → Paises_Monedas → Planes_Precios_Localizados.
-- 2. monto_bruto = precio_local del plan en la moneda del mercado del cliente.
-- 3. retencion_regalias y margen_operativo son columnas calculadas en la tabla
--    → no se insertan explícitamente, SQL Server las computa on-read.
-- 4. codigo_moneda se desnormaliza en Pagos para evitar un JOIN en cada
--    query de MRR y royalties.
-- ==============================================================================
DECLARE @hoy DATE = CAST(SYSUTCDATETIME() AS DATE);

-- Materializar: suscripción → precio local → código de moneda
SELECT
    s.id_suscripcion,
    s.id_cliente,
    s.id_plan,
    s.fecha_inicio,
    s.fecha_fin,
    ppl.precio_local,
    pm.codigo_moneda
INTO #ClientePrecio
FROM core.Suscripciones     s
INNER JOIN core.Clientes              c   ON s.id_cliente = c.id_cliente
INNER JOIN core.Paises_Monedas        pm  ON c.id_pais    = pm.id_pais
INNER JOIN core.Planes_Precios_Localizados ppl
    ON s.id_plan = ppl.id_plan AND c.id_pais = ppl.id_pais;

CREATE CLUSTERED INDEX IX_CP ON #ClientePrecio (id_suscripcion);

-- Planes mensuales (1–4): un pago por mes dentro del período activo
INSERT INTO core.Pagos (id_suscripcion, id_metodo, codigo_moneda, monto_bruto, fecha_pago, estado_pago)
SELECT
    cp.id_suscripcion,
    CAST(ABS(CHECKSUM(NEWID())) % 5 + 1 AS TINYINT)          AS id_metodo,
    cp.codigo_moneda,
    cp.precio_local                                            AS monto_bruto,
    CAST(DATEADD(month, t.n, cp.fecha_inicio) AS DATE)        AS fecha_pago,
    CASE
        WHEN t.n = 0 AND ABS(CHECKSUM(NEWID())) % 100 < 3 THEN 'fallido'
        WHEN t.n > 0 AND ABS(CHECKSUM(NEWID())) % 100 < 5 THEN 'fallido'
        ELSE 'exitoso'
    END                                                        AS estado_pago
FROM #ClientePrecio cp
CROSS JOIN #Tally   t
WHERE cp.id_plan IN (1,2,3,4)
  AND t.n <= CASE
        WHEN DATEDIFF(month, cp.fecha_inicio, ISNULL(cp.fecha_fin, @hoy)) < 0
        THEN 0
        ELSE DATEDIFF(month, cp.fecha_inicio, ISNULL(cp.fecha_fin, @hoy))
     END
  AND CAST(DATEADD(month, t.n, cp.fecha_inicio) AS DATE) <= ISNULL(cp.fecha_fin, @hoy);

-- Plan Anual (5): pago único al inicio
INSERT INTO core.Pagos (id_suscripcion, id_metodo, codigo_moneda, monto_bruto, fecha_pago, estado_pago)
SELECT
    cp.id_suscripcion,
    CAST(ABS(CHECKSUM(NEWID())) % 5 + 1 AS TINYINT)          AS id_metodo,
    cp.codigo_moneda,
    cp.precio_local                                            AS monto_bruto,
    cp.fecha_inicio                                            AS fecha_pago,
    CASE WHEN ABS(CHECKSUM(NEWID())) % 100 < 3 THEN 'fallido' ELSE 'exitoso' END
FROM #ClientePrecio cp
WHERE cp.id_plan = 5;

DROP TABLE #ClientePrecio;
GO

-- ==============================================================================
-- BLOQUE 9: SIMULACIÓN DE SESIONES (1–3 por cliente) — UTC absoluto
-- Suscripción de referencia: la más reciente por cliente.
-- IP en rango 190.x (ISPs Claro/Movistar Perú/LATAM).
-- ~10% de sesiones quedan activas (activa=1, fecha_fin=NULL).
-- ==============================================================================
DECLARE @hoy_dt DATETIME2(0) = CAST(SYSUTCDATETIME() AS DATETIME2(0));

SELECT
    c.id_cliente,
    s.id_suscripcion,
    s.fecha_inicio,
    ISNULL(s.fecha_fin, CAST(@hoy_dt AS DATE)) AS fecha_fin_efectiva,
    ABS(CHECKSUM(NEWID())) % 3                 AS sesiones_extra  -- 0,1,2 → total 1–3
INTO #SuscActiva
FROM core.Clientes c
INNER JOIN core.Suscripciones s ON s.id_cliente = c.id_cliente;

-- Deduplicar: conservar solo la suscripción más reciente por cliente
;WITH Ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY id_cliente ORDER BY id_suscripcion DESC) AS rn
    FROM #SuscActiva
)
DELETE FROM Ranked WHERE rn > 1;

CREATE CLUSTERED INDEX IX_SA ON #SuscActiva (id_cliente);

INSERT INTO core.Sesiones
    (id_cliente, id_suscripcion, fecha_inicio_sesion, fecha_fin_sesion,
     ip_address, dispositivo, activa)
SELECT
    sa.id_cliente,
    sa.id_suscripcion,
    CAST(DATEADD(minute,
        -(ABS(CHECKSUM(NEWID())) % 10080),
        @hoy_dt) AS DATETIME2(0))                              AS fecha_inicio_sesion,
    CASE
        WHEN ABS(CHECKSUM(NEWID())) % 10 = 0 THEN NULL        -- ~10% activas
        ELSE CAST(DATEADD(minute,
                5 + ABS(CHECKSUM(NEWID())) % 116,
                DATEADD(minute,
                    -(ABS(CHECKSUM(NEWID())) % 10080),
                    @hoy_dt)) AS DATETIME2(0))
    END                                                        AS fecha_fin_sesion,
    '190.' + CAST(ABS(CHECKSUM(NEWID())) % 256 AS VARCHAR(3))
           + '.' + CAST(ABS(CHECKSUM(NEWID())) % 256 AS VARCHAR(3))
           + '.' + CAST(ABS(CHECKSUM(NEWID())) % 256 AS VARCHAR(3)) AS ip_address,
    CASE ABS(CHECKSUM(NEWID())) % 6
        WHEN 0 THEN N'Android Mobile'
        WHEN 1 THEN N'iOS Mobile'
        WHEN 2 THEN N'Windows Desktop'
        WHEN 3 THEN N'MacOS Desktop'
        WHEN 4 THEN N'Smart TV'
        ELSE        N'Web Browser'
    END                                                        AS dispositivo,
    CASE WHEN ABS(CHECKSUM(NEWID())) % 10 = 0 THEN 1 ELSE 0 END AS activa
FROM #SuscActiva sa
CROSS JOIN (SELECT n FROM #Tally WHERE n BETWEEN 0 AND 2) idx
WHERE idx.n <= sa.sesiones_extra;

DROP TABLE #SuscActiva;
GO

-- ==============================================================================
-- BLOQUE 10: SIMULACIÓN DE ACTIVIDAD — Batch ETL nocturno (UTC)
-- Mismo flujo de 3 pasos de v5.0. Sin cambios lógicos.
-- ==============================================================================
DECLARE @hoy DATE = CAST(SYSUTCDATETIME() AS DATE);

CREATE TABLE #Fechas_Base (fecha DATE NOT NULL PRIMARY KEY CLUSTERED);

INSERT INTO #Fechas_Base (fecha)
SELECT CAST(DATEADD(day, -t.n, @hoy) AS DATE)
FROM #Tally t
WHERE t.n BETWEEN 0 AND 179;

CREATE TABLE #Actividad_Stage (
    id_cliente INT      NOT NULL,
    fecha      DATE     NOT NULL,
    minutos    SMALLINT NOT NULL,
    PRIMARY KEY CLUSTERED (id_cliente, fecha)
);

INSERT INTO #Actividad_Stage (id_cliente, fecha, minutos)
SELECT
    s.id_cliente,
    f.fecha,
    CAST(
        CASE
            WHEN ABS(CHECKSUM(NEWID())) % 100 < 15 THEN 0
            WHEN ABS(CHECKSUM(NEWID())) % 100 < 60
                THEN 15 + ABS(CHECKSUM(
                        CAST(s.id_cliente AS VARCHAR(10))
                        + CAST(f.fecha AS VARCHAR(12)))) % 46
            ELSE
                60  + ABS(CHECKSUM(
                        CAST(s.id_cliente AS VARCHAR(10))
                        + CAST(f.fecha AS VARCHAR(12)))) % 91
        END
    AS SMALLINT)
FROM core.Suscripciones s
INNER JOIN #Fechas_Base f
    ON  f.fecha >= s.fecha_inicio
    AND f.fecha <= COALESCE(s.fecha_fin, @hoy);

INSERT INTO analytics.Actividad_Usuario
    (id_cliente, fecha_actividad, minutos_escuchados, canciones_reproducidas)
SELECT
    id_cliente,
    fecha,
    minutos,
    CAST(CASE WHEN minutos = 0 THEN 0 ELSE minutos / 3 END AS SMALLINT)
FROM #Actividad_Stage;

DROP TABLE #Actividad_Stage;
DROP TABLE #Fechas_Base;
DROP TABLE #Tally;
GO

-- ==============================================================================
-- BLOQUE 11: AUDITORÍA FINAL DE INTEGRIDAD
-- ==============================================================================
SET NOCOUNT OFF;

-- 1. Conteo por tabla
SELECT esquema_tabla, filas FROM (
    SELECT 'core.Metodos_Pago'              AS esquema_tabla, COUNT(*) AS filas FROM core.Metodos_Pago
    UNION ALL SELECT 'core.Paises_Monedas',                   COUNT(*) FROM core.Paises_Monedas
    UNION ALL SELECT 'core.Planes',                           COUNT(*) FROM core.Planes
    UNION ALL SELECT 'core.Planes_Precios_Localizados',       COUNT(*) FROM core.Planes_Precios_Localizados
    UNION ALL SELECT 'core.Clientes',                         COUNT(*) FROM core.Clientes
    UNION ALL SELECT 'core.Suscripciones',                    COUNT(*) FROM core.Suscripciones
    UNION ALL SELECT 'core.Pagos',                            COUNT(*) FROM core.Pagos
    UNION ALL SELECT 'core.Sesiones',                         COUNT(*) FROM core.Sesiones
    UNION ALL SELECT 'analytics.Actividad_Usuario',           COUNT(*) FROM analytics.Actividad_Usuario
) r ORDER BY esquema_tabla;

-- 2. Suscripciones solapadas → debe retornar 0 filas
SELECT a.id_cliente, a.id_suscripcion AS susc_a, b.id_suscripcion AS susc_b,
       a.fecha_inicio, a.fecha_fin, b.fecha_inicio AS inicio_b
FROM core.Suscripciones a
JOIN core.Suscripciones b
    ON  a.id_cliente     = b.id_cliente
    AND a.id_suscripcion < b.id_suscripcion
    AND a.fecha_inicio   < ISNULL(b.fecha_fin, '9999-12-31')
    AND b.fecha_inicio   < ISNULL(a.fecha_fin, '9999-12-31');

-- 3. Actividad fuera de período de suscripción → debe retornar 0 filas
SELECT au.id_cliente, au.fecha_actividad
FROM analytics.Actividad_Usuario au
WHERE NOT EXISTS (
    SELECT 1 FROM core.Suscripciones s
    WHERE s.id_cliente       = au.id_cliente
      AND au.fecha_actividad >= s.fecha_inicio
      AND au.fecha_actividad <= ISNULL(s.fecha_fin, CAST(SYSUTCDATETIME() AS DATE))
);

-- 4. Pagos con FK huérfana en id_metodo → debe retornar 0 filas
SELECT p.id_pago, p.id_metodo
FROM core.Pagos p
WHERE NOT EXISTS (SELECT 1 FROM core.Metodos_Pago m WHERE m.id_metodo = p.id_metodo);

-- 5. Sesiones sin FK válida en id_suscripcion → debe retornar 0 filas
SELECT se.id_sesion, se.id_suscripcion
FROM core.Sesiones se
WHERE NOT EXISTS (
    SELECT 1 FROM core.Suscripciones s WHERE s.id_suscripcion = se.id_suscripcion
);

-- 6. Precios localizados faltantes (debe mostrar 30 filas: 5 planes × 6 países)
SELECT COUNT(*) AS combinaciones_precio FROM core.Planes_Precios_Localizados;

-- 7. Distribución Geo-Pricing: precio promedio por plan × mercado + Streamshare
SELECT
    pl.nombre_plan,
    pm.nombre_pais,
    pm.codigo_moneda,
    ppl.precio_local,
    CAST(ppl.precio_local * 0.70 AS DECIMAL(10,2)) AS regalias_estimadas,
    CAST(ppl.precio_local * 0.30 AS DECIMAL(10,2)) AS margen_estimado,
    COUNT(p.id_pago)                                AS pagos_generados,
    CAST(SUM(p.monto_bruto) AS DECIMAL(12,2))       AS ingresos_brutos_totales
FROM core.Planes_Precios_Localizados ppl
INNER JOIN core.Planes        pl ON ppl.id_plan = pl.id_plan
INNER JOIN core.Paises_Monedas pm ON ppl.id_pais = pm.id_pais
LEFT JOIN core.Suscripciones   s
    ON s.id_plan = ppl.id_plan
LEFT JOIN core.Clientes         c
    ON c.id_cliente = s.id_cliente AND c.id_pais = ppl.id_pais
LEFT JOIN core.Pagos            p
    ON p.id_suscripcion = s.id_suscripcion AND p.codigo_moneda = pm.codigo_moneda
GROUP BY pl.id_plan, pm.id_pais, pl.nombre_plan, pm.nombre_pais, pm.codigo_moneda, ppl.precio_local
ORDER BY pl.id_plan, pm.id_pais;
GO
-- 8. Distribución de dispositivos en sesiones
SELECT dispositivo,
       COUNT(*) AS total,
       CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER() AS DECIMAL(5,2)) AS pct
FROM core.Sesiones
GROUP BY dispositivo
ORDER BY total DESC;
GO