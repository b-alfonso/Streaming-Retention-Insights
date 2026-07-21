-- ==============================================================================
-- SCRIPT 02 | STREAMING RETENTION INSIGHTS (CORREGIDO Y AJUSTADO)
-- Versión: 4.1 | Analytics & Data Engineering | SQL Server 2019+
-- ==============================================================================

USE Streaming_Retention_Insights_v2;
GO

DECLARE @filtro_id_pais  TINYINT = NULL;   
DECLARE @filtro_id_plan  TINYINT = NULL;   
DECLARE @meses_horizonte TINYINT = 6;      

DECLARE @hoy           DATE = CAST(SYSUTCDATETIME() AS DATE);
DECLARE @mes_corte     DATE = DATEFROMPARTS(YEAR(@hoy), MONTH(@hoy), 1);
DECLARE @ultimo_mes    DATE = DATEADD(month, -1, @mes_corte);

DECLARE @txt_pais VARCHAR(50) = ISNULL((SELECT nombre_pais FROM core.Paises_Monedas WHERE id_pais = @filtro_id_pais), 'GLOBAL');
DECLARE @txt_plan VARCHAR(50) = ISNULL((SELECT nombre_plan FROM core.Planes WHERE id_plan = @filtro_id_plan), 'TODOS');

;WITH PrimerasSuscripciones AS (
    SELECT
        id_cliente,
        id_plan                                                      AS id_plan_cohorte,
        fecha_inicio,
        DATEFROMPARTS(YEAR(fecha_inicio), MONTH(fecha_inicio), 1)    AS cohorte_mes
    FROM (
        SELECT
            id_cliente,
            id_plan,
            fecha_inicio,
            ROW_NUMBER() OVER (PARTITION BY id_cliente ORDER BY fecha_inicio ASC) AS rn
        FROM core.Suscripciones
        WHERE fecha_inicio < @mes_corte       
    ) sub
    WHERE rn = 1
),

CohortesFiltradas AS (
    SELECT
        ps.id_cliente,
        ps.cohorte_mes
    FROM PrimerasSuscripciones ps
    INNER JOIN core.Clientes    c ON ps.id_cliente = c.id_cliente
    WHERE ps.cohorte_mes <= @ultimo_mes                               
      AND (@filtro_id_pais IS NULL OR c.id_pais          = @filtro_id_pais)
      AND (@filtro_id_plan IS NULL OR ps.id_plan_cohorte = @filtro_id_plan)
),

TamañoCohorteBase AS (
    SELECT
        cohorte_mes,
        COUNT(DISTINCT id_cliente) AS clientes_cohorte
    FROM CohortesFiltradas
    GROUP BY cohorte_mes
),

SeñalesActividad AS (
    SELECT
        s.id_cliente,
        DATEFROMPARTS(YEAR(p.fecha_pago), MONTH(p.fecha_pago), 1) AS mes_activo
    FROM core.Pagos p
    INNER JOIN core.Suscripciones s ON p.id_suscripcion = s.id_suscripcion
    WHERE p.estado_pago = 'exitoso' AND p.fecha_pago < @mes_corte

    UNION 

    SELECT
        id_cliente,
        DATEFROMPARTS(YEAR(fecha_actividad), MONTH(fecha_actividad), 1) AS mes_activo
    FROM analytics.Actividad_Usuario
    WHERE minutos_escuchados > 0 AND fecha_actividad < @mes_corte
),

MesesPorCliente AS (
    SELECT
        cf.id_cliente,
        cf.cohorte_mes,
        CASE 
            WHEN DATEDIFF(month, cf.cohorte_mes, sa.mes_activo) <= 0 THEN 0 
            ELSE DATEDIFF(month, cf.cohorte_mes, sa.mes_activo) 
        END AS meses_desde_cohorte
    FROM CohortesFiltradas cf
    INNER JOIN SeñalesActividad sa ON cf.id_cliente = sa.id_cliente
    WHERE sa.mes_activo <= @ultimo_mes                  
),

-- NUEVA CTE: Agrupamos los clientes activos por cohorte y mes transcurrido ANTES del pivote
ClientesActivosPorMes AS (
    SELECT 
        cohorte_mes,
        meses_desde_cohorte,
        COUNT(DISTINCT id_cliente) AS clientes_activos
    FROM MesesPorCliente
    GROUP BY cohorte_mes, meses_desde_cohorte
)

-- ==============================================================================
-- MATRIZ PIVOTE FINAL (SIN ANIDACIÓN DE AGREGADOS)
-- ==============================================================================
SELECT
    FORMAT(tc.cohorte_mes, 'yyyy-MM')                                        AS cohorte,
    @txt_pais                                                                AS pais,
    @txt_plan                                                                AS plan_estudio,
    tc.clientes_cohorte                                                      AS n_cohorte,

    '100.0%'                                                                 AS [Mes 0],
    
    ISNULL(MAX(CASE WHEN ca.meses_desde_cohorte = 1 THEN FORMAT(CAST(ca.clientes_activos AS FLOAT) / NULLIF(tc.clientes_cohorte, 0) * 100, 'N1') + '%' END), '—') AS [Mes 1],
    ISNULL(MAX(CASE WHEN ca.meses_desde_cohorte = 2 THEN FORMAT(CAST(ca.clientes_activos AS FLOAT) / NULLIF(tc.clientes_cohorte, 0) * 100, 'N1') + '%' END), '—') AS [Mes 2],
    ISNULL(MAX(CASE WHEN ca.meses_desde_cohorte = 3 THEN FORMAT(CAST(ca.clientes_activos AS FLOAT) / NULLIF(tc.clientes_cohorte, 0) * 100, 'N1') + '%' END), '—') AS [Mes 3],
    ISNULL(MAX(CASE WHEN ca.meses_desde_cohorte = 4 THEN FORMAT(CAST(ca.clientes_activos AS FLOAT) / NULLIF(tc.clientes_cohorte, 0) * 100, 'N1') + '%' END), '—') AS [Mes 4],
    ISNULL(MAX(CASE WHEN ca.meses_desde_cohorte = 5 THEN FORMAT(CAST(ca.clientes_activos AS FLOAT) / NULLIF(tc.clientes_cohorte, 0) * 100, 'N1') + '%' END), '—') AS [Mes 5],
    ISNULL(MAX(CASE WHEN ca.meses_desde_cohorte = 6 THEN FORMAT(CAST(ca.clientes_activos AS FLOAT) / NULLIF(tc.clientes_cohorte, 0) * 100, 'N1') + '%' END), '—') AS [Mes 6]
FROM TamañoCohorteBase tc
LEFT JOIN ClientesActivosPorMes ca ON tc.cohorte_mes = ca.cohorte_mes
GROUP BY tc.cohorte_mes, tc.clientes_cohorte
ORDER BY cohorte ASC;
GO