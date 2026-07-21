-- ==============================================================================
-- SCRIPT 04 | PREVENCIÓN: CLIENTES EN RIESGO DE CANCELACIÓN (CHURN RISK)
-- Versión: 1.0 | Analytics & Data Engineering | SQL Server 2019+
-- ==============================================================================

USE Streaming_Retention_Insights_v2;
GO

-- ==============================================================================
-- 1. PARÁMETROS GLOBALES (Consistencia de Portafolio)
-- ==============================================================================
DECLARE @filtro_id_pais  TINYINT = NULL;   
DECLARE @filtro_id_plan  TINYINT = NULL;   
DECLARE @hoy DATE = '2026-06-18';

-- ==============================================================================
-- 2. PARÁMETROS DE NEGOCIO (Umbrales de Riesgo Ajustables)
-- ==============================================================================
DECLARE @MinutosBajaActividad     INT = 30; -- Menos de 30 min/día promedio en últimos 7 días
DECLARE @DiasInactividad          INT = 7;  -- Período de observación de actividad
DECLARE @DiasPagoFallido          INT = 30; -- Pagos fallidos en los últimos N días
DECLARE @DiasProximoVencimiento   INT = 15; -- Suscripción a punto de terminar
DECLARE @MesesAntiguedadRiesgo    INT = 6;  -- Clientes activos más de 6 meses

;WITH 
-- 1. Actividad reciente del usuario
ActividadReciente AS (
    SELECT 
        id_cliente,
        AVG(minutos_escuchados * 1.0) AS promedio_minutos_diarios,
        COUNT(DISTINCT fecha_actividad) AS dias_con_actividad
    FROM analytics.Actividad_Usuario
    WHERE fecha_actividad >= DATEADD(day, -@DiasInactividad, @hoy)
    GROUP BY id_cliente
),

-- 2. Pagos fallidos recientes
PagosFallidos AS (
    SELECT 
        s.id_cliente,
        COUNT(p.id_pago) AS total_fallidos_recientes
    FROM core.Pagos p
    INNER JOIN core.Suscripciones s ON p.id_suscripcion = s.id_suscripcion
    WHERE p.estado_pago = 'fallido'
      AND p.fecha_pago >= DATEADD(day, -@DiasPagoFallido, @hoy)
    GROUP BY s.id_cliente
),

-- 3. Identificar la suscripción activa más reciente por cliente
SuscripcionActiva AS (
    SELECT 
        id_cliente,
        id_suscripcion,
        id_plan,
        fecha_inicio,
        fecha_fin,
        estado,
        ROW_NUMBER() OVER (PARTITION BY id_cliente ORDER BY fecha_inicio DESC) AS rn
    FROM core.Suscripciones
    -- Validamos tanto el string 'activa' como el estándar de fechas NULL para evitar falsos positivos
    WHERE estado = 'activa' 
      AND (fecha_fin IS NULL OR fecha_fin >= @hoy)
),
SuscripcionesActuales AS (
    SELECT * FROM SuscripcionActiva WHERE rn = 1
),

-- 4. Motor de Riesgo (Cruces y Flags)
RiesgoCalculado AS (
    SELECT 
        c.id_cliente,
        c.email,
        pm.nombre_pais AS pais,
        c.edad,
        sa.id_plan,
        p.nombre_plan,
        sa.fecha_inicio,
        sa.fecha_fin,
        DATEDIFF(day, sa.fecha_inicio, @hoy) AS dias_activo,
        
        -- Métricas crudas
        ISNULL(ar.promedio_minutos_diarios, 0) AS promedio_minutos,
        ISNULL(ar.dias_con_actividad, 0) AS dias_activos_periodo,
        ISNULL(pf.total_fallidos_recientes, 0) AS pagos_fallidos,
        
        -- Señales Binarias (1 = En Riesgo, 0 = Sano)
        CASE WHEN ISNULL(ar.promedio_minutos_diarios, 0) < @MinutosBajaActividad 
              AND ar.dias_con_actividad > 0 THEN 1 ELSE 0 END AS riesgo_baja_actividad,
              
        CASE WHEN ISNULL(pf.total_fallidos_recientes, 0) > 0 THEN 1 ELSE 0 END AS riesgo_pagos_fallidos,
        
        CASE WHEN sa.fecha_fin IS NOT NULL 
              AND p.nombre_plan NOT LIKE '%Anual%'
              AND DATEDIFF(day, @hoy, sa.fecha_fin) BETWEEN 0 AND @DiasProximoVencimiento THEN 1 ELSE 0 END AS riesgo_proximo_vencimiento,
              
        CASE WHEN DATEDIFF(day, sa.fecha_inicio, @hoy) > (@MesesAntiguedadRiesgo * 30) 
              AND ISNULL(ar.promedio_minutos_diarios, 0) < (@MinutosBajaActividad * 0.5) THEN 1 ELSE 0 END AS riesgo_antiguo_inactivo

    FROM core.Clientes c
    INNER JOIN SuscripcionesActuales sa ON c.id_cliente = sa.id_cliente
    INNER JOIN core.Planes p ON sa.id_plan = p.id_plan
    LEFT JOIN core.Paises_Monedas pm ON c.id_pais = pm.id_pais
    LEFT JOIN ActividadReciente ar ON c.id_cliente = ar.id_cliente
    LEFT JOIN PagosFallidos pf ON c.id_cliente = pf.id_cliente
    -- Filtros globales
    WHERE (@filtro_id_pais IS NULL OR c.id_pais = @filtro_id_pais)
      AND (@filtro_id_plan IS NULL OR sa.id_plan = @filtro_id_plan)
)

-- ==============================================================================
-- 5. REPORTE FINAL: Puntuación y Recomendación de Acción
-- ==============================================================================
SELECT 
    id_cliente,
    email,
    pais,
    edad,
    nombre_plan,
    fecha_inicio,
    fecha_fin,
    dias_activo,
    promedio_minutos,
    pagos_fallidos,
    
    (riesgo_baja_actividad + riesgo_pagos_fallidos + riesgo_proximo_vencimiento + riesgo_antiguo_inactivo) AS puntaje_riesgo,
    
    CASE 
        WHEN (riesgo_baja_actividad + riesgo_pagos_fallidos + riesgo_proximo_vencimiento + riesgo_antiguo_inactivo) >= 3 THEN 'Muy Alto - Contactar inmediatamente'
        WHEN (riesgo_baja_actividad + riesgo_pagos_fallidos + riesgo_proximo_vencimiento + riesgo_antiguo_inactivo) = 2 THEN 'Alto - Ofrecer descuento o engagement'
        WHEN (riesgo_baja_actividad + riesgo_pagos_fallidos + riesgo_proximo_vencimiento + riesgo_antiguo_inactivo) = 1 THEN 'Medio - Monitorear'
        ELSE 'Bajo - Sin acción inmediata'
    END AS nivel_riesgo,
    
    -- Diagnóstico dinámico
    CONCAT(
        CASE WHEN riesgo_baja_actividad = 1 THEN 'Baja actividad. ' ELSE '' END,
        CASE WHEN riesgo_pagos_fallidos = 1 THEN 'Pagos fallidos. ' ELSE '' END,
        CASE WHEN riesgo_proximo_vencimiento = 1 THEN 'Suscripción por vencer. ' ELSE '' END,
        CASE WHEN riesgo_antiguo_inactivo = 1 THEN 'Antiguo e inactivo. ' ELSE '' END
    ) AS recomendacion

FROM RiesgoCalculado
WHERE (riesgo_baja_actividad + riesgo_pagos_fallidos + riesgo_proximo_vencimiento + riesgo_antiguo_inactivo) >= 1
ORDER BY puntaje_riesgo DESC, promedio_minutos ASC;
GO