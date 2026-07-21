-- ==============================================================================
-- SCRIPT 03 | CHURN DE CLIENTES, CHURN DE INGRESOS (MRR) Y LTV POR COHORTE
-- Versión: 2.0 | Analytics & Data Engineering | SQL Server 2019+
-- ==============================================================================

-- ==============================================================================
-- PARTE 1: CHURN MENSUAL DE CLIENTES
-- ==============================================================================
USE Streaming_Retention_Insights_v2;
GO

DECLARE @filtro_id_pais  TINYINT = NULL;
DECLARE @filtro_id_plan  TINYINT = NULL;

;WITH MesesCompletos AS (
    SELECT DISTINCT DATEFROMPARTS(YEAR(fecha_inicio), MONTH(fecha_inicio), 1) AS mes_inicio
    FROM core.Suscripciones
),
SuscripcionesFiltradas AS (
    SELECT 
        s.id_cliente, 
        s.fecha_inicio, 
        s.fecha_fin
    FROM core.Suscripciones s
    INNER JOIN core.Clientes c ON s.id_cliente = c.id_cliente
    WHERE (@filtro_id_pais IS NULL OR c.id_pais = @filtro_id_pais)
      AND (@filtro_id_plan IS NULL OR s.id_plan = @filtro_id_plan)
),
ClientesActivosInicioMes AS (
    SELECT 
        m.mes_inicio, 
        s.id_cliente
    FROM MesesCompletos m
    INNER JOIN SuscripcionesFiltradas s 
        ON s.fecha_inicio <= m.mes_inicio
        AND (s.fecha_fin IS NULL OR s.fecha_fin >= m.mes_inicio)
    GROUP BY m.mes_inicio, s.id_cliente
),
ChurnClientes AS (
    SELECT 
        a.mes_inicio,
        COUNT(DISTINCT a.id_cliente) AS clientes_activos_inicio,
        SUM(CASE WHEN b.id_cliente IS NULL THEN 1 ELSE 0 END) AS clientes_cancelaron
    FROM ClientesActivosInicioMes a
    INNER JOIN MesesCompletos m_next 
        ON m_next.mes_inicio = DATEADD(month, 1, a.mes_inicio)
    LEFT JOIN ClientesActivosInicioMes b
        ON a.id_cliente = b.id_cliente
        AND b.mes_inicio = m_next.mes_inicio
    GROUP BY a.mes_inicio
)
SELECT 
    FORMAT(mes_inicio, 'yyyy-MM') AS mes_analisis,
    clientes_activos_inicio,
    clientes_cancelaron,
    FORMAT(ROUND(100.0 * clientes_cancelaron / NULLIF(clientes_activos_inicio, 0), 2), 'N2') + '%' AS churn_clientes_porcentaje
FROM ChurnClientes
ORDER BY mes_inicio;
GO

-- ==============================================================================
-- PARTE 2: CHURN DE INGRESOS (MRR CHURN) - OPTIMIZADA POR PAGOS
-- ==============================================================================
USE Streaming_Retention_Insights_v2;
GO

DECLARE @filtro_id_pais  TINYINT = NULL;
DECLARE @filtro_id_plan  TINYINT = NULL;

;WITH MesesCompletos AS (
    SELECT DISTINCT DATEFROMPARTS(YEAR(fecha_inicio), MONTH(fecha_inicio), 1) AS mes_inicio
    FROM core.Suscripciones
),
-- Calculamos el ingreso mensual promedio por suscripción basado en pagos exitosos
IngresoPorSuscripcion AS (
    SELECT 
        id_suscripcion,
        AVG(monto_bruto) AS precio_estimado_mensual
    FROM core.Pagos
    WHERE estado_pago = 'exitoso'
    GROUP BY id_suscripcion
),
SuscripcionesFiltradas AS (
    SELECT 
        s.id_cliente, 
        s.fecha_inicio, 
        s.fecha_fin,
        ISNULL(p.precio_estimado_mensual, 0) AS mrr_contribucion
    FROM core.Suscripciones s
    INNER JOIN core.Clientes c ON s.id_cliente = c.id_cliente
    LEFT JOIN IngresoPorSuscripcion p ON s.id_suscripcion = p.id_suscripcion
    WHERE (@filtro_id_pais IS NULL OR c.id_pais = @filtro_id_pais)
      AND (@filtro_id_plan IS NULL OR s.id_plan = @filtro_id_plan)
),
ClientesActivosMensual AS (
    SELECT 
        m.mes_inicio,
        s.id_cliente,
        s.mrr_contribucion,
        ROW_NUMBER() OVER (PARTITION BY m.mes_inicio, s.id_cliente ORDER BY s.fecha_inicio DESC) AS rn
    FROM MesesCompletos m
    INNER JOIN SuscripcionesFiltradas s 
        ON s.fecha_inicio <= m.mes_inicio
        AND (s.fecha_fin IS NULL OR s.fecha_fin >= m.mes_inicio)
),
ClientesActivosInicioMes AS (
    SELECT 
        mes_inicio, 
        id_cliente, 
        mrr_contribucion
    FROM ClientesActivosMensual
    WHERE rn = 1
),
MRR_InicioMes AS (
    SELECT 
        mes_inicio, 
        SUM(mrr_contribucion) AS mrr_total_inicio
    FROM ClientesActivosInicioMes
    GROUP BY mes_inicio
),
MRR_Perdido AS (
    SELECT 
        a.mes_inicio,
        SUM(a.mrr_contribucion) AS mrr_perdido
    FROM ClientesActivosInicioMes a
    INNER JOIN MesesCompletos m_next 
        ON m_next.mes_inicio = DATEADD(month, 1, a.mes_inicio)
    LEFT JOIN ClientesActivosInicioMes b
        ON a.id_cliente = b.id_cliente
        AND b.mes_inicio = m_next.mes_inicio
    WHERE b.id_cliente IS NULL
    GROUP BY a.mes_inicio
)
SELECT 
    FORMAT(i.mes_inicio, 'yyyy-MM') AS mes_analisis,
    ROUND(i.mrr_total_inicio, 2) AS mrr_total_inicio,
    ROUND(ISNULL(p.mrr_perdido, 0), 2) AS mrr_perdido,
    FORMAT(ROUND(100.0 * ISNULL(p.mrr_perdido, 0) / NULLIF(i.mrr_total_inicio, 0), 2), 'N2') + '%' AS churn_ingresos_porcentaje
FROM MRR_InicioMes i
LEFT JOIN MRR_Perdido p ON i.mes_inicio = p.mes_inicio
ORDER BY i.mes_inicio;
GO

-- ==============================================================================
-- PARTE 3: LIFETIME VALUE (LTV) POR COHORTE
-- ==============================================================================
USE Streaming_Retention_Insights_v2;
GO

DECLARE @filtro_id_pais  TINYINT = NULL;
DECLARE @filtro_id_plan  TINYINT = NULL;

;WITH PrimeraSuscripcion AS (
    SELECT 
        id_cliente,
        id_plan_cohorte,
        cohorte_mes
    FROM (
        SELECT 
            id_cliente,
            id_plan AS id_plan_cohorte,
            DATEFROMPARTS(YEAR(fecha_inicio), MONTH(fecha_inicio), 1) AS cohorte_mes,
            ROW_NUMBER() OVER (PARTITION BY id_cliente ORDER BY fecha_inicio ASC) AS rn
        FROM core.Suscripciones
    ) sub
    WHERE rn = 1
),
CohortesFiltradas AS (
    SELECT 
        ps.id_cliente,
        ps.cohorte_mes
    FROM PrimeraSuscripcion ps
    INNER JOIN core.Clientes c ON ps.id_cliente = c.id_cliente
    WHERE (@filtro_id_pais IS NULL OR c.id_pais = @filtro_id_pais)
      AND (@filtro_id_plan IS NULL OR ps.id_plan_cohorte = @filtro_id_plan)
),
PagosCliente AS (
    SELECT 
        s.id_cliente,
        -- NOTA: Verifica si tu columna en core.Pagos se llama 'monto' o 'monto_bruto' y ajusta si es necesario
        SUM(p.monto_bruto) AS total_pagado 
    FROM core.Pagos p
    INNER JOIN core.Suscripciones s ON p.id_suscripcion = s.id_suscripcion
    WHERE p.estado_pago = 'exitoso'
    GROUP BY s.id_cliente
),
LTVxCohorte AS (
    SELECT 
        cf.cohorte_mes,
        COUNT(DISTINCT cf.id_cliente) AS total_clientes_cohorte,
        SUM(ISNULL(pc.total_pagado, 0)) AS ingresos_totales_cohorte
    FROM CohortesFiltradas cf
    LEFT JOIN PagosCliente pc ON cf.id_cliente = pc.id_cliente
    GROUP BY cf.cohorte_mes
)
SELECT 
    FORMAT(cohorte_mes, 'yyyy-MM') AS cohorte,
    total_clientes_cohorte,
    ROUND(ingresos_totales_cohorte, 2) AS ingresos_totales_cohorte,
    ROUND(ingresos_totales_cohorte / NULLIF(CAST(total_clientes_cohorte AS FLOAT), 0), 2) AS ltv_promedio_soles
FROM LTVxCohorte
ORDER BY cohorte_mes;
GO